import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { PASSWORD_POLICY_MESSAGE, validatePassword } from '../security/password.js';
import { normalizeNickname } from '../security/profile-onboarding.js';
import { registerMaxWebsiteAccount } from '../services/max-chat-registration.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const BCRYPT_ROUNDS = 12;

export function registerSignup(router, database = pool) {
  router.post('/signup', async (req, res) => {
    try {
      const { email, password } = req.body;
      if (!email || !password) {
        return res.status(400).json({ error: 'Email and password required' });
      }

      const normalizedEmail = email.toLowerCase().trim();
      if (!EMAIL_RE.test(normalizedEmail)) {
        return res.status(400).json({ error: 'Invalid email format' });
      }

      if (!validatePassword(password)) {
        return res.status(400).json({ error: PASSWORD_POLICY_MESSAGE });
      }

      const existing = await database.query('SELECT id FROM auth.users WHERE email = $1', [normalizedEmail]);
      const maxRegistration = req.body.data?.max_registration;
      if (existing.rows.length > 0) {
        if (maxRegistration) return res.status(409).json({ code: 'EMAIL_IN_USE', error: 'Почта уже зарегистрирована. Войди в свой аккаунт.' });
        return res.status(200).json({
          message: 'If this email is not registered, a confirmation will be sent.',
        });
      }

      const hashed = await bcrypt.hash(password, BCRYPT_ROUNDS);
      const usernameFromBody = req.body.data?.username || req.body.options?.data?.username || normalizedEmail.split('@')[0];
      if (maxRegistration) {
        const username = normalizeNickname(usernameFromBody);
        if (!username) return res.status(422).json({ error: 'Никнейм должен содержать от 3 до 30 символов.' });
        const result = await registerMaxWebsiteAccount(database, {
          registration: maxRegistration, email: normalizedEmail, passwordHash: hashed, username,
        });
        if (!result.user) {
          const errors = {
            INVALID_MAX_REGISTRATION: 'Код регистрации не подошёл. Проверь код из чата MAX или запроси новую ссылку.',
            EMAIL_IN_USE: 'Почта уже зарегистрирована. Войди в свой аккаунт.',
            NICKNAME_TAKEN: 'Этот никнейм уже занят.',
          };
          return res.status(409).json({ code: result.code, error: errors[result.code] });
        }
        return res.json({
          session: null,
          user: { ...result.user, email_confirmed_at: null, app_metadata: { provider: 'email' }, user_metadata: { username } },
        });
      }
      const metadata = { username: String(usernameFromBody).slice(0,80), session_version: 0 };
      const referralCode = req.body.data?.signup_referral_code ?? req.body.options?.data?.signup_referral_code;
      if (typeof referralCode === 'string' && /^[a-z0-9_-]{3,20}$/i.test(referralCode)) {
        metadata.signup_referral_code = referralCode.toLowerCase();
      }
      if (req.body.data?.studio_consents === true) metadata.studio_consents = { terms: '2026-11-02', privacy: '2026-11-02', accepted_at: new Date().toISOString() };

      const result = await database.query(
        `INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
         VALUES ($1, $2, NULL, $3::jsonb, now(), now())
         RETURNING id, email, created_at`,
        [normalizedEmail, hashed, JSON.stringify(metadata)]
      );

      const user = result.rows[0];
      user.raw_user_meta_data = metadata;
      user.session_version = 0;

      await database.query(
        `INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
         VALUES ($1, $2, $2, $3, 100, now(), now())
         ON CONFLICT (user_id) DO UPDATE SET
           username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
           display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
           email = COALESCE(EXCLUDED.email, public.profiles.email)`,
        [user.id, usernameFromBody, normalizedEmail]
      );

      res.status(200).json({
        session: null,
        user: {
          id: user.id,
          email: user.email,
          created_at: user.created_at,
          email_confirmed_at: null,
          app_metadata: { provider: 'email' },
          user_metadata: { username: usernameFromBody },
        },
      });
    } catch (err) {
      console.error('[Auth] Signup error:', err.message);
      res.status(500).json({ error: 'Registration failed' });
    }
  });
}
