import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { requireServiceRole, signToken } from '../middleware/auth.js';
import { PASSWORD_POLICY_MESSAGE, validatePassword } from '../security/password.js';

export function registerAdmin(router) {
  router.post('/admin/impersonation-session', requireServiceRole, async (req, res) => {
    try {
      const { user_id: userId } = req.body;
      if (!userId) {
        return res.status(400).json({ error: 'user_id is required' });
      }

      const result = await pool.query(
        `SELECT u.id, u.email, u.email_confirmed_at, u.created_at, u.is_super_admin, u.raw_user_meta_data,
                p.role AS app_role, p.display_name
         FROM auth.users u
         LEFT JOIN public.profiles p ON p.user_id = u.id
         WHERE u.id = $1`,
        [userId]
      );
      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }

      const user = result.rows[0];
      user.app_role = user.app_role || 'user';
      user.session_version = Number(user.raw_user_meta_data?.session_version ?? 0);
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
          user_metadata: { display_name: user.display_name },
          is_super_admin: user.is_super_admin || false,
        },
      });
    } catch (err) {
      console.error('[Admin] Impersonation session error:', err.message);
      res.status(500).json({ error: 'Failed to create impersonation session' });
    }
  });

  router.get('/admin/users', requireServiceRole, async (req, res) => {
    try {
      const page = parseInt(req.query.page) || 1;
      const perPage = parseInt(req.query.per_page) || 50;
      const offset = (page - 1) * perPage;

      const result = await pool.query(
        `SELECT id, email, encrypted_password, email_confirmed_at, is_super_admin,
                raw_user_meta_data, created_at, updated_at, last_sign_in_at
         FROM auth.users
         ORDER BY created_at DESC
         LIMIT $1 OFFSET $2`,
        [perPage, offset]
      );

      const countResult = await pool.query('SELECT COUNT(*) FROM auth.users');
      const total = parseInt(countResult.rows[0].count);

      res.json({
        users: result.rows.map(u => ({
          id: u.id,
          email: u.email,
          email_confirmed_at: u.email_confirmed_at,
          is_super_admin: u.is_super_admin || false,
          user_metadata: u.raw_user_meta_data || {},
          created_at: u.created_at,
          updated_at: u.updated_at,
          last_sign_in_at: u.last_sign_in_at,
        })),
        total,
        page,
        per_page: perPage,
      });
    } catch (err) {
      console.error('[Admin] List users error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  router.get('/admin/users/:id', requireServiceRole, async (req, res) => {
    try {
      const result = await pool.query(
        `SELECT u.id, u.email, u.email_confirmed_at, u.is_super_admin,
                u.raw_user_meta_data, u.created_at, u.updated_at, u.last_sign_in_at,
                p.role AS app_role, p.username, p.display_name, p.avatar_url, p.balance
         FROM auth.users u
         LEFT JOIN public.profiles p ON p.user_id = u.id
         WHERE u.id = $1`,
        [req.params.id]
      );
      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }
      const u = result.rows[0];
      res.json({
        id: u.id,
        email: u.email,
        email_confirmed_at: u.email_confirmed_at,
        is_super_admin: u.is_super_admin || false,
        user_metadata: u.raw_user_meta_data || {},
        app_role: u.app_role || 'user',
        username: u.username,
        display_name: u.display_name,
        avatar_url: u.avatar_url,
        balance: u.balance,
        created_at: u.created_at,
        updated_at: u.updated_at,
        last_sign_in_at: u.last_sign_in_at,
      });
    } catch (err) {
      console.error('[Admin] Get user error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  router.post('/admin/users', requireServiceRole, async (req, res) => {
    try {
      const { email, password, email_confirm, user_metadata } = req.body;
      if (!email || !password) {
        return res.status(400).json({ error: 'Email and password required' });
      }
      if (!validatePassword(password)) {
        return res.status(400).json({ error: PASSWORD_POLICY_MESSAGE });
      }

      const existing = await pool.query('SELECT id FROM auth.users WHERE email = $1', [email.toLowerCase()]);
      if (existing.rows.length > 0) {
        return res.status(400).json({ error: 'User already registered', code: 'USER_EXISTS' });
      }

      const hashed = await bcrypt.hash(password, 12);
      const meta = user_metadata || {};
      const username = meta.username || email.split('@')[0];

      const result = await pool.query(
        `INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
         VALUES ($1, $2, $3, $4::jsonb, now(), now())
         RETURNING id, email, email_confirmed_at, created_at`,
        [email.toLowerCase(), hashed, email_confirm ? new Date().toISOString() : null, JSON.stringify(meta)]
      );

      const user = result.rows[0];

      await pool.query(
        `INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
         VALUES ($1, $2, $2, $3, 100, now(), now())
         ON CONFLICT (user_id) DO UPDATE SET
           username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
           display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
           email = COALESCE(EXCLUDED.email, public.profiles.email)`,
        [user.id, username, email.toLowerCase()]
      );

      res.status(200).json({
        user: {
          id: user.id,
          email: user.email,
          email_confirmed_at: user.email_confirmed_at,
          created_at: user.created_at,
          user_metadata: meta,
        },
      });
    } catch (err) {
      console.error('[Admin] Create user error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  router.put('/admin/users/:id', requireServiceRole, async (req, res) => {
    try {
      const userId = req.params.id;
      const { email, password, email_confirm, user_metadata, ban_duration } = req.body;
      const passwordChanged = Boolean(password);

      const updates = [];
      const params = [];
      let idx = 1;

      if (email) {
        updates.push(`email = $${idx++}`);
        params.push(email.toLowerCase());
      }
      if (password) {
        if (!validatePassword(password)) {
          return res.status(400).json({ error: PASSWORD_POLICY_MESSAGE });
        }
        const hashed = await bcrypt.hash(password, 12);
        updates.push(`encrypted_password = $${idx++}`);
        params.push(hashed);
        updates.push(`raw_user_meta_data = jsonb_set(
          COALESCE(raw_user_meta_data, '{}'::jsonb),
          '{session_version}',
          to_jsonb(CASE
            WHEN COALESCE(raw_user_meta_data->>'session_version', '') ~ '^\\d+$'
              THEN (raw_user_meta_data->>'session_version')::integer + 1
            ELSE 1
          END),
          true
        )`);
      }
      if (email_confirm === true) {
        updates.push(`email_confirmed_at = COALESCE(email_confirmed_at, now())`);
      }
      if (email_confirm === false) {
        updates.push(`email_confirmed_at = NULL`);
      }
      if (user_metadata) {
        updates.push(`raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || $${idx++}::jsonb`);
        params.push(JSON.stringify(user_metadata));
      }
      if (ban_duration) {
        updates.push(`banned_until = now() + $${idx}::interval`);
        params.push(ban_duration);
        idx++;
      }

      updates.push('updated_at = now()');
      params.push(userId);

      if (updates.length <= 1) {
        const result = await pool.query(
          'SELECT id, email, email_confirmed_at, raw_user_meta_data, created_at FROM auth.users WHERE id = $1',
          [userId]
        );
        const u = result.rows[0];
        if (!u) return res.status(404).json({ error: 'User not found' });
        return res.json({ id: u.id, email: u.email, email_confirmed_at: u.email_confirmed_at });
      }

      const updateSql = `UPDATE auth.users SET ${updates.join(', ')} WHERE id = $${idx} RETURNING id, email, email_confirmed_at, raw_user_meta_data, created_at`;
      const sql = passwordChanged
        ? `WITH updated AS (${updateSql}),
             deleted_tokens AS (
               DELETE FROM public.email_verifications
               WHERE email IN (SELECT email FROM updated) AND code LIKE 'RESET:%'
             )
           SELECT * FROM updated`
        : updateSql;
      const result = await pool.query(sql, params);

      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }

      const u = result.rows[0];
      res.json({
        id: u.id,
        email: u.email,
        email_confirmed_at: u.email_confirmed_at,
        user_metadata: u.raw_user_meta_data || {},
        created_at: u.created_at,
      });
    } catch (err) {
      console.error('[Admin] Update user error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });

  router.delete('/admin/users/:id', requireServiceRole, async (req, res) => {
    try {
      const userId = req.params.id;

      const check = await pool.query(
        'SELECT is_super_admin FROM auth.users WHERE id = $1',
        [userId]
      );
      if (check.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }
      if (check.rows[0].is_super_admin) {
        return res.status(403).json({ error: 'Cannot delete super admin' });
      }

      await pool.query('DELETE FROM public.profiles WHERE user_id = $1', [userId]);
      await pool.query('DELETE FROM auth.users WHERE id = $1', [userId]);

      res.json({ id: userId });
    } catch (err) {
      console.error('[Admin] Delete user error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });
}
