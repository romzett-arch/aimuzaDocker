import crypto from 'crypto';
import { pool } from '../db.js';
import { requireServiceRole } from '../middleware/auth.js';

const BASE_URL = process.env.BASE_URL || 'http://localhost';

export function registerRecovery(router) {
  router.post('/admin/generate_link', requireServiceRole, async (req, res) => {
    try {
      const { type, email, options } = req.body;
      const redirectTo = options?.redirectTo || `${BASE_URL}/auth?mode=reset`;

      if (!email) {
        return res.status(400).json({ error: 'Email required' });
      }

      const userResult = await pool.query(
        'SELECT id, email FROM auth.users WHERE email = $1',
        [email.toLowerCase()]
      );
      if (userResult.rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }

      if (type === 'recovery') {
        const token = crypto.randomBytes(32).toString('hex');

        await pool.query(
          `INSERT INTO public.email_verifications (email, code, verified, expires_at)
           VALUES ($1, $2, false, now() + interval '1 hour')`,
          [email.toLowerCase(), `RESET:${token}`]
        );

        const actionLink = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}&type=recovery`;

        res.json({
          data: {
            properties: {
              action_link: actionLink,
              hashed_token: token,
            },
          },
        });
      } else if (type === 'signup' || type === 'magiclink') {
        const token = crypto.randomBytes(32).toString('hex');
        const actionLink = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}&type=${type}`;

        res.json({
          data: {
            properties: {
              action_link: actionLink,
            },
          },
        });
      } else {
        res.status(400).json({ error: `Unsupported link type: ${type}` });
      }
    } catch (err) {
      console.error('[Admin] Generate link error:', err.message);
      res.status(500).json({ error: err.message });
    }
  });
}
