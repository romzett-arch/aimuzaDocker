import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';

export function registerUser(router) {
  router.get('/user', requireAuth, async (req, res) => {
    try {
      const result = await pool.query(
        'SELECT id, email, created_at, is_super_admin, raw_user_meta_data FROM auth.users WHERE id = $1',
        [req.user.id]
      );
      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }
      const user = result.rows[0];

      const profileRes = await pool.query(
        'SELECT role, is_super_admin, display_name, username FROM public.profiles WHERE user_id = $1',
        [user.id]
      );
      const profile = profileRes.rows[0];

      res.json({
        id: user.id,
        email: user.email,
        created_at: user.created_at,
        is_super_admin: user.is_super_admin || false,
        app_metadata: { provider: 'email', role: profile?.role || 'user' },
        user_metadata: {
          ...(user.raw_user_meta_data || {}),
          display_name: profile?.display_name || profile?.username,
        },
      });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  router.put('/user', requireAuth, async (req, res) => {
    try {
      const { password, email, data: metaData } = req.body;
      const updates = [];
      const params = [];
      let idx = 1;

      if (password) {
        const hashed = await bcrypt.hash(password, 10);
        updates.push(`encrypted_password = $${idx++}`);
        params.push(hashed);
      }
      if (email) {
        updates.push(`email = $${idx++}`);
        params.push(email.toLowerCase());
      }
      if (metaData) {
        updates.push(`raw_user_meta_data = raw_user_meta_data || $${idx++}::jsonb`);
        params.push(JSON.stringify(metaData));
      }

      updates.push(`updated_at = now()`);
      params.push(req.user.id);

      const result = await pool.query(
        `UPDATE auth.users SET ${updates.join(', ')} WHERE id = $${idx} RETURNING id, email, created_at`,
        params
      );

      const user = result.rows[0];
      res.json({
        id: user.id,
        email: user.email,
        created_at: user.created_at,
      });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });
}
