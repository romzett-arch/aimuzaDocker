import assert from 'node:assert/strict';
import express from 'express';
import { pool } from '../src/db.js';
import { registerYandexId } from '../src/routes/auth-yandex.js';
import { registerVkId } from '../src/routes/auth-vkid.js';
import { secret, digest } from '../src/security/yandex.js';

const nativeFetch = globalThis.fetch;
let expectedState;
globalThis.fetch = async (url, options) => {
  assert.equal(options.redirect, 'error');
  if (String(url) === 'https://oauth.yandex.ru/token') return { ok: true, json: async () => ({ access_token: 'fake-provider-token' }) };
  assert.equal(String(url), 'https://login.yandex.ru/info?format=json');
  assert.equal(options.headers.Authorization, 'OAuth fake-provider-token');
  return { ok: true, json: async () => ({ id: '999999999999', default_email: 'yandex-http-fixture@example.invalid', client_id: process.env.YANDEX_CLIENT_ID || 'e0e64eae06f84e5dabb798f9e757f648' }) };
};
const app = express();
app.use(express.json());
const connection = await pool.connect();
await connection.query('BEGIN');
const transaction = { query: (sql, params) => ['BEGIN','COMMIT','ROLLBACK'].includes(sql) ? Promise.resolve({ rows: [] }) : connection.query(sql, params), release() {} };
registerYandexId(app, { query: transaction.query, connect: async () => transaction });
registerVkId(app, { query: transaction.query, connect: async () => transaction });
const server = app.listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
const base = 'http://127.0.0.1:' + server.address().port;
const post = (path, body) => nativeFetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const states = [];
let checks = 0;
try {
  const referrer = (await connection.query(
    'INSERT INTO auth.users(email,email_confirmed_at) VALUES($1,now()) RETURNING id',
    ['yandex-referrer@example.invalid'],
  )).rows[0].id;
  await connection.query("INSERT INTO public.referral_codes(user_id,code) VALUES($1,'TEST-REF')", [referrer]);
  await connection.query("UPDATE public.referral_settings SET value='true' WHERE key='program_enabled'");
  await connection.query("UPDATE public.referral_settings SET value='100' WHERE key='max_referrals_per_user'");
  const binding = secret();
  let r = await post('/yandex/start', { binding: digest(binding), destination: 'https://evil.example' });
  assert.equal(r.status, 400); checks++;
  r = await post('/yandex/start', { binding: digest(binding), destination: 'site', link: true });
  assert.equal(r.status, 401); checks++;
  for (const input of [{ consent: false }, { consent: true }, { consent: 'true', consentVersion: 'yandex-2026-11-03' }]) {
    r = await post('/yandex/start', { binding: digest(binding), destination: 'site', ...input });
    assert.equal(r.status, 422); checks++;
    assert.equal((await r.json()).error, 'YANDEX_CONSENT_REQUIRED'); checks++;
  }
  r = await post('/yandex/start', { binding: digest(binding), destination: 'studio', loginOnly: true, consent: true, consentVersion: 'yandex-2026-11-03' });
  assert.equal(r.status, 200); checks++;
  const loginStateHash = digest(new URL((await r.json()).url).searchParams.get('state'));
  assert.equal((await connection.query('SELECT consent FROM auth.yandex_flows WHERE state_hash=$1', [loginStateHash])).rows[0].consent, false); checks++;
  r = await post('/yandex/start', { binding: digest(binding), destination: 'site', consent: true, consentVersion: 'yandex-2026-11-03' });
  assert.equal(r.status, 200); checks++;
  const authorize = new URL((await r.json()).url);
  expectedState = authorize.searchParams.get('state'); states.push(digest(expectedState));
  r = await nativeFetch(base + '/yandex/callback?' + new URLSearchParams({ state: expectedState, code: 'fixture-code', device_id: 'fixture-device' }), { redirect: 'manual' });
  assert.equal(r.status, 303); checks++;
  assert.equal(r.headers.get('referrer-policy'), 'no-referrer'); checks++;
  const finish = new URL(r.headers.get('location'));
  const ticket = new URLSearchParams(finish.hash.slice(1)).get('ticket');
  assert.ok(ticket); checks++;
  r = await post('/yandex/exchange', { ticket, binding: secret(), destination: 'site' });
  assert.equal((await r.json()).error, 'YANDEX_EXPIRED'); checks++;
  r = await post('/yandex/exchange', { ticket, binding, destination: 'studio' });
  assert.equal((await r.json()).error, 'YANDEX_EXPIRED'); checks++;
  // A wrong destination may consume the owner's ticket but cannot authenticate anyone.
  assert.equal((await connection.query('SELECT count(*)::int AS n FROM auth.yandex_identities WHERE subject=$1', ['999999999999'])).rows[0].n, 0); checks++;
  r = await nativeFetch(base + '/yandex/callback?' + new URLSearchParams({ state: expectedState, code: 'replayed', device_id: 'fixture-device' }), { redirect: 'manual' });
  assert.match(r.headers.get('location'), /yandex_error/); checks++;
  r = await post('/yandex/exchange', { ticket, binding, destination: 'site' });
  assert.equal((await r.json()).error, 'YANDEX_EXPIRED'); checks++;
  r = await post('/yandex/start', { binding: digest(binding), destination: 'site', referralCode: 'test-ref', consent: true, consentVersion: 'yandex-2026-11-03' });
  const nextAuthorize = new URL((await r.json()).url);
  expectedState = nextAuthorize.searchParams.get('state'); states.push(digest(expectedState));
  r = await nativeFetch(base + '/yandex/callback?' + new URLSearchParams({ state: expectedState, code: 'second-code', device_id: 'fixture-device' }), { redirect: 'manual' });
  const nextTicket = new URLSearchParams(new URL(r.headers.get('location')).hash.slice(1)).get('ticket');
  r = await post('/vkid/exchange', { ticket: nextTicket, binding, destination: 'site' });
  assert.equal((await r.json()).error, 'VKID_EXPIRED'); checks++;
  r = await post('/yandex/exchange', { ticket: nextTicket, binding, destination: 'site' });
  assert.equal(r.status, 200); checks++;
  const session = await r.json();
  assert.ok(session.access_token && session.refresh_token && session.user.id); checks++;
  const attribution = (await connection.query('SELECT referrer_id,source FROM public.referrals WHERE referee_id=$1', [session.user.id])).rows[0];
  assert.deepEqual(attribution, { referrer_id: referrer, source: 'yandex' }); checks++;
  const accepted = (await connection.query('SELECT raw_user_meta_data FROM auth.users WHERE id=$1', [session.user.id])).rows[0].raw_user_meta_data.registration_consents;
  assert.equal(accepted.license_agreement && accepted.audit_policy && accepted.personal_data, true); checks++;
  assert.equal(JSON.parse(Buffer.from(session.access_token.split('.')[1], 'base64url').toString()).session_origin, 'yandex'); checks++;
  assert.equal((await connection.query('SELECT count(*)::int AS n FROM public.api_refresh_sessions WHERE user_id=$1', [session.user.id])).rows[0].n, 1); checks++;
  r = await post('/yandex/exchange', { ticket: nextTicket, binding, destination: 'site' });
  assert.equal((await r.json()).error, 'YANDEX_EXPIRED'); checks++;
  console.log(`Yandex ID HTTP checks passed: ${checks}. All fixtures rolled back.`);
} finally {
  globalThis.fetch = nativeFetch;
  await connection.query('ROLLBACK');
  connection.release();
  await new Promise(resolve => server.close(resolve));
  await pool.end();
}
