import crypto from 'crypto';
import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { requireServiceRole } from '../middleware/auth.js';
import {
  hashRecoveryToken,
  normalizeRecoveryToken,
  PASSWORD_POLICY_MESSAGE,
  recoveryCodeForToken,
  validatePassword,
} from '../security/password.js';

const BASE_URL = process.env.BASE_URL || 'http://localhost';

export function registerRecovery(router) {
  router.post('/recover', async (req, res) => {
    const token = normalizeRecoveryToken(req.body?.token);
    const { password } = req.body || {};

    if (!token) {
      return res.status(400).json({ error: 'Ссылка на сброс неверна или устарела' });
    }
    if (!validatePassword(password)) {
      return res.status(400).json({ error: PASSWORD_POLICY_MESSAGE });
    }

    let client;
    try {
      client = await pool.connect();
      await client.query('BEGIN');
      const verificationResult = await client.query(
        `SELECT id, email
         FROM public.email_verifications
         WHERE code = ANY($1::text[]) AND verified = false AND expires_at > now()
         ORDER BY created_at DESC
         LIMIT 1
         FOR UPDATE`,
        [[recoveryCodeForToken(token), `RESET:${token}`]]
      );

      if (verificationResult.rows.length === 0) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Ссылка на сброс неверна или устарела' });
      }

      const { email } = verificationResult.rows[0];
      const hashedPassword = await bcrypt.hash(password, 12);
      const updateResult = await client.query(
        `UPDATE auth.users
         SET encrypted_password = $1,
             raw_user_meta_data = jsonb_set(
               COALESCE(raw_user_meta_data, '{}'::jsonb),
               '{session_version}',
               to_jsonb(CASE
                 WHEN COALESCE(raw_user_meta_data->>'session_version', '') ~ '^\\d+$'
                   THEN (raw_user_meta_data->>'session_version')::integer + 1
                 ELSE 1
               END),
               true
             ),
             updated_at = now()
         WHERE email = $2
         RETURNING id`,
        [hashedPassword, email]
      );

      if (updateResult.rows.length === 0) {
        throw new Error('Recovery user no longer exists');
      }

      await client.query(
        `DELETE FROM public.email_verifications
         WHERE email = $1 AND code LIKE 'RESET:%'`,
        [email]
      );
      await client.query('COMMIT');
      return res.json({ success: true });
    } catch (err) {
      await client?.query('ROLLBACK').catch(() => {});
      console.error('[Auth] Password recovery error:', err.message);
      return res.status(500).json({ error: 'Не удалось изменить пароль' });
    } finally {
      client?.release();
    }
  });

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
          `DELETE FROM public.email_verifications
           WHERE email = $1 AND code LIKE 'RESET:%'`,
          [email.toLowerCase()]
        );
        await pool.query(
          `INSERT INTO public.email_verifications (email, code, verified, expires_at)
           VALUES ($1, $2, false, now() + interval '1 hour')`,
          [email.toLowerCase(), recoveryCodeForToken(token)]
        );

        const actionLink = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}&type=recovery`;

        res.json({
          data: {
            properties: {
              action_link: actionLink,
              hashed_token: hashRecoveryToken(token),
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
