import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { signToken } from '../middleware/auth.js';

export function registerSignup(router) {
  router.post('/signup', async (req, res) => {
    try {
      const { email, password } = req.body;
      if (!email || !password) {
        return res.status(400).json({ error: 'Email and password required' });
      }

      const existing = await pool.query('SELECT id FROM auth.users WHERE email = $1', [email.toLowerCase()]);
      if (existing.rows.length > 0) {
        return res.status(400).json({ error: 'User already registered', code: 'USER_EXISTS' });
      }

      const hashed = await bcrypt.hash(password, 10);
      const usernameFromBody = req.body.data?.username || req.body.options?.data?.username || email.split('@')[0];
      const metadata = { username: usernameFromBody, ...(req.body.data || {}) };

      const result = await pool.query(
        `INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
         VALUES ($1, $2, NULL, $3::jsonb, now(), now())
         RETURNING id, email, created_at`,
        [email.toLowerCase(), hashed, JSON.stringify(metadata)]
      );

      const user = result.rows[0];

      await pool.query(
        `INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
         VALUES ($1, $2, $2, $3, 100, now(), now())
         ON CONFLICT (user_id) DO UPDATE SET
           username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
           display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
           email = COALESCE(EXCLUDED.email, public.profiles.email)`,
        [user.id, usernameFromBody, email.toLowerCase()]
      );

      const token = signToken(user);

      res.status(200).json({
        access_token: token,
        token_type: 'bearer',
        expires_in: 604800,
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
      res.status(500).json({ error: err.message });
    }
  });
}
