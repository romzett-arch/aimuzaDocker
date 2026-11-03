import rateLimit from 'express-rate-limit';
import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { signToken, requireAuth } from '../middleware/auth.js';
import { freshRoles, issueRefresh } from '../security/refresh-session.js';
import { authorizeUrl, configuration, digest, secret, validSecret, fail, providerProfile, finishUrl } from '../security/vkid.js';

const limiter = rateLimit({ windowMs: 15 * 60000, limit: 40 });
const protectedUser = user => !user || user.raw_user_meta_data?.deleted_at || !user.email_confirmed_at;

export async function resolveVkUser(client, flow) {
  const profile = { ...flow.profile, email: (flow.profile.email || '').trim().toLowerCase() };
  // Lock a provider subject even before its identity exists, preventing duplicate registrations.
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', ['vkid:' + profile.subject]);
  const identity = (await client.query('SELECT user_id FROM auth.vkid_identities WHERE subject=$1', [profile.subject])).rows[0];
  if (flow.link_user_id) {
    const user = (await client.query('SELECT * FROM auth.users WHERE id=$1 FOR UPDATE', [flow.link_user_id])).rows[0];
    if (protectedUser(user) || Number(user.raw_user_meta_data?.session_version || 0) !== flow.link_version) fail('VKID_SESSION_EXPIRED');
    if (identity && identity.user_id !== user.id) fail('VKID_ALREADY_LINKED');
    const existing = (await client.query('SELECT subject FROM auth.vkid_identities WHERE user_id=$1', [user.id])).rows[0];
    if (existing && existing.subject !== profile.subject) fail('VKID_ALREADY_LINKED');
    await client.query('INSERT INTO auth.vkid_identities(subject,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [profile.subject, user.id]);
    return user;
  }
  if (identity) {
    const user = (await client.query('SELECT * FROM auth.users WHERE id=$1 FOR UPDATE', [identity.user_id])).rows[0];
    if (protectedUser(user)) fail('VKID_ACCOUNT_UNAVAILABLE');
    return user;
  }
  if (!flow.consent) fail('VKID_CONSENT_REQUIRED');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(profile.email) || profile.email.length > 120) fail('VKID_EMAIL_REQUIRED');
  // Matching email is not proof of ownership of an existing AIMUZA account.
  if ((await client.query('SELECT id FROM auth.users WHERE lower(email)=$1', [profile.email])).rowCount) fail('VKID_LINK_REQUIRED');
  const password = await bcrypt.hash(secret(), 12);
  const metadata = { provider: 'vkid', session_version: 0, nickname_required: true, username: 'vk_' + secret().slice(0, 24),
    registration_consents: { source: 'vkid', schema: 'vkid-2026-11-03', license_agreement: true, audit_policy: true, personal_data: true, accepted_at: new Date().toISOString() },
    studio_consents: { terms: '2026-11-02', privacy: '2026-11-02', accepted_at: new Date().toISOString() } };
  const user = (await client.query(`INSERT INTO auth.users(email,encrypted_password,email_confirmed_at,raw_user_meta_data,created_at,updated_at)
    VALUES($1,$2,now(),$3,now(),now()) RETURNING *`, [profile.email, password, metadata])).rows[0];
  const username = 'vk_' + user.id.replaceAll('-', '');
  await client.query(`INSERT INTO public.profiles(user_id,username,display_name,email,balance,created_at,updated_at)
    VALUES($1,$2,$3,$4,100,now(),now()) ON CONFLICT(user_id) DO UPDATE SET display_name=$3`, [user.id, username, profile.name || 'Пользователь', profile.email]);
  await client.query('INSERT INTO auth.vkid_identities(subject,user_id) VALUES($1,$2)', [profile.subject, user.id]);
  return user;
}

export function registerVkId(router, database = pool) {
  router.use('/vkid', (_req, res, next) => { res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' }); next(); });
  router.get('/vkid/config', (_req, res) => res.json({ enabled: configuration().enabled }));
  router.get('/vkid/identity', requireAuth, async (req, res, next) => {
    try { res.json({ linked: Boolean((await database.query('SELECT 1 FROM auth.vkid_identities WHERE user_id=$1', [req.user.id])).rowCount) }); } catch (e) { next(e); }
  });
  router.post('/vkid/start', limiter, async (req, res) => {
    try {
      const config = configuration();
      if (!config.enabled) return res.status(503).json({ error: 'VKID_DISABLED' });
      const { destination, binding, link, consent, consentVersion } = req.body;
      if (!['site','studio','android'].includes(destination) || !/^[a-f0-9]{64}$/.test(binding || '')) fail('VKID_INVALID_REQUEST');
      if (link && (!req.user?.id || req.user.id === 'service-role')) return res.status(401).json({ error: 'VKID_AUTH_REQUIRED' });
      if (!link && (consent !== true || consentVersion !== 'vkid-2026-11-03')) return res.status(422).json({ error: 'VKID_CONSENT_REQUIRED' });
      const expectedOrigin = destination === 'site' ? config.site : config.studio;
      if (req.headers.origin && req.headers.origin !== expectedOrigin) fail('VKID_INVALID_ORIGIN');
      const state = secret(), verifier = secret();
      await database.query('DELETE FROM auth.vkid_flows WHERE expires_at<now()');
      await database.query(`INSERT INTO auth.vkid_flows(state_hash,binding_hash,verifier,destination,link_user_id,link_version,consent)
        VALUES($1,$2,$3,$4,$5,$6,$7)`, [digest(state), binding, verifier, destination, link ? req.user.id : null, link ? req.user.session_version : null, consent === true]);
      res.json({ url: authorizeUrl(config, state, verifier) });
    } catch { res.status(400).json({ error: 'VKID_START_FAILED' }); }
  });
  router.get('/vkid/callback', limiter, async (req, res) => {
    let client;
    let flow;
    try {
      client = await database.connect();
      if (!configuration().enabled || !validSecret(req.query.state)) fail('VKID_INVALID_CALLBACK');
      // Consume state before talking to VK; a callback can never be replayed.
      flow = (await client.query('DELETE FROM auth.vkid_flows WHERE state_hash=$1 AND expires_at>now() AND ticket_hash IS NULL RETURNING *', [digest(req.query.state)])).rows[0];
      if (!flow) fail('VKID_EXPIRED');
      if (req.query.error) fail('VKID_CANCELLED');
      const profile = await providerProfile(configuration(), flow, req.query);
      const ticket = secret();
      await client.query(`INSERT INTO auth.vkid_flows(state_hash,binding_hash,verifier,destination,link_user_id,link_version,consent,profile,ticket_hash,expires_at)
        VALUES($1,$2,'',$3,$4,$5,$6,$7,$8,now()+interval '90 seconds')`, [flow.state_hash, flow.binding_hash, flow.destination, flow.link_user_id, flow.link_version, flow.consent, profile, digest(ticket)]);
      res.redirect(303, finishUrl(configuration(), flow.destination, ticket));
    } catch (error) {
      const config = configuration();
      const target = flow?.destination === 'site' ? config.site + '/auth' : config.studio + '/';
      res.redirect(303, target + '?vkid_error=VKID_CANCELLED_OR_FAILED');
    } finally { client?.release(); }
  });
  router.post('/vkid/exchange', limiter, async (req, res) => {
    if (!configuration().enabled) return res.status(503).json({ error: 'VKID_DISABLED' });
    const { ticket, binding, destination } = req.body;
    if (!validSecret(ticket) || !validSecret(binding)) return res.status(400).json({ error: 'VKID_INVALID_REQUEST' });
    let client;
    try {
      client = await database.connect();
      await client.query('BEGIN');
      const flow = (await client.query(`DELETE FROM auth.vkid_flows WHERE ticket_hash=$1 AND binding_hash=$2 AND destination=$3 AND expires_at>now() RETURNING *`, [digest(ticket), digest(binding), destination])).rows[0];
      if (!flow || !flow.profile) fail('VKID_EXPIRED');
      if (flow.link_user_id && (req.user?.id !== flow.link_user_id || req.user.session_version !== flow.link_version)) fail('VKID_SESSION_EXPIRED');
      const user = await resolveVkUser(client, flow);
      const current = await freshRoles(client, { ...user, session_origin: 'vkid' });
      const access_token = signToken(current), refresh_token = await issueRefresh(client, current);
      await client.query('UPDATE auth.users SET last_sign_in_at=now() WHERE id=$1', [user.id]);
      await client.query('COMMIT');
      res.json({ access_token, refresh_token, expires_in: 900, token_type: 'bearer',
        user: { id: user.id, email: user.email, created_at: user.created_at, user_metadata: user.raw_user_meta_data || {}, app_metadata: { provider: 'vkid', role: current.app_role } } });
    } catch (error) {
      await client?.query('ROLLBACK').catch(() => {});
      // Failed policy checks consume the ticket too; never leave a reusable credential.
      await client?.query('DELETE FROM auth.vkid_flows WHERE ticket_hash=$1 AND binding_hash=$2', [digest(ticket), digest(binding)]).catch(() => {});
      const safe = ['VKID_LINK_REQUIRED','VKID_EMAIL_REQUIRED','VKID_CONSENT_REQUIRED','VKID_ALREADY_LINKED','VKID_SESSION_EXPIRED','VKID_ACCOUNT_UNAVAILABLE','VKID_EXPIRED'];
      res.status(400).json({ error: safe.includes(error.code) ? error.code : 'VKID_EXCHANGE_FAILED' });
    } finally { client?.release(); }
  });
}
