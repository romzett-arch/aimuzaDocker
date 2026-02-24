import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { signToken } from '../middleware/auth.js';

export function registerToken(router) {
  router.post('/token', async (req, res) => {
    try {
      const grantType = req.query.grant_type || req.body.grant_type;

      if (grantType === 'password') {
        const { email, password } = req.body;
        if (!email || !password) {
          return res.status(400).json({ error: 'Email and password required' });
        }

        const result = await pool.query(
          'SELECT id, email, encrypted_password, email_confirmed_at, created_at, is_super_admin FROM auth.users WHERE email = $1',
          [email.toLowerCase()]
        );

        if (result.rows.length === 0) {
          return res.status(400).json({ error: 'Invalid login credentials', code: 'INVALID_CREDENTIALS' });
        }

        const user = result.rows[0];
        const valid = await bcrypt.compare(password, user.encrypted_password);
        if (!valid) {
          return res.status(400).json({ error: 'Invalid login credentials', code: 'INVALID_CREDENTIALS' });
        }

        if (!user.email_confirmed_at) {
          return res.status(400).json({
            error: 'Email not confirmed',
            code: 'EMAIL_NOT_CONFIRMED',
            message: 'Подтвердите email перед входом. Проверьте почту.',
          });
        }

        const profileRes = await pool.query(
          'SELECT role, is_super_admin, display_name FROM public.profiles WHERE user_id = $1',
          [user.id]
        );
        const profile = profileRes.rows[0];
        user.app_role = profile?.role || 'user';
        user.is_super_admin = user.is_super_admin || profile?.is_super_admin || false;

        await pool.query('UPDATE auth.users SET last_sign_in_at = now() WHERE id = $1', [user.id]);

        const token = signToken(user);

        return res.json({
          access_token: token,
          token_type: 'bearer',
          expires_in: 604800,
          refresh_token: token,
          user: {
            id: user.id,
            email: user.email,
            created_at: user.created_at,
            email_confirmed_at: user.email_confirmed_at,
            app_metadata: { provider: 'email', role: user.app_role },
            user_metadata: { display_name: profile?.display_name },
            is_super_admin: user.is_super_admin,
          },
        });
      }

      if (grantType === 'refresh_token') {
        if (!req.user) {
          return res.status(401).json({ error: 'Invalid refresh token' });
        }
        const result = await pool.query('SELECT id, email, created_at FROM auth.users WHERE id = $1', [req.user.id]);
        if (result.rows.length === 0) {
          return res.status(401).json({ error: 'User not found' });
        }
        const user = result.rows[0];
        const token = signToken(user);
        return res.json({
          access_token: token,
          token_type: 'bearer',
          expires_in: 604800,
          refresh_token: token,
          user: {
            id: user.id,
            email: user.email,
            created_at: user.created_at,
            app_metadata: { provider: 'email' },
            user_metadata: {},
          },
        });
      }

      res.status(400).json({ error: 'Unsupported grant_type' });
    } catch (err) {
      console.error('[Auth] Token error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  router.post('/logout', (req, res) => {
    res.status(204).end();
  });
}
