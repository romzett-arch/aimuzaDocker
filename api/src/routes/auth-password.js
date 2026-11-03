import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { requireAuth, signToken } from '../middleware/auth.js';
import { freshRoles, issueRefresh } from '../security/refresh-session.js';
import { readSessionVersion } from '../security/session-version.js';
import { PASSWORD_POLICY_MESSAGE, validatePassword } from '../security/password.js';

// Rotate credentials atomically without forcing the current client through logout.
export function registerPassword(router, database = pool) {
  router.post('/password', requireAuth, async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (req.user.role === 'service_role' || req.user.session_origin === 'impersonation') {
      return res.status(403).json({ error: 'Для установки пароля войдите в собственный аккаунт' });
    }
    const password = req.body?.password;
    if (!validatePassword(password)) return res.status(400).json({ error: PASSWORD_POLICY_MESSAGE });
    let client;
    try {
      const hashed = await bcrypt.hash(password, 12);
      client = await database.connect();
      await client.query('BEGIN');
      const user = (await client.query('SELECT * FROM auth.users WHERE id=$1 FOR UPDATE', [req.user.id])).rows[0];
      if (!user?.email_confirmed_at || readSessionVersion(user) !== readSessionVersion(req.user)) {
        await client.query('ROLLBACK');
        return res.status(401).json({ error: 'Сессия уже завершена. Войдите заново.' });
      }
      const nextVersion = readSessionVersion(user) + 1;
      const updated = (await client.query(`UPDATE auth.users SET encrypted_password=$2,
        raw_user_meta_data=jsonb_set(COALESCE(raw_user_meta_data,'{}'::jsonb),'{session_version}',to_jsonb($3::bigint),true),
        updated_at=now() WHERE id=$1 RETURNING *`, [user.id, hashed, nextVersion])).rows[0];
      await client.query('DELETE FROM public.api_refresh_sessions WHERE user_id=$1', [user.id]);
      // Setting a password must not upgrade an OAuth/legacy session's provenance.
      const current = await freshRoles(client, { ...updated, session_origin: req.user.session_origin || 'legacy' });
      const access_token = signToken(current);
      const refresh_token = await issueRefresh(client, current);
      await client.query('COMMIT');
      return res.json({ access_token, refresh_token, expires_in: 900, token_type: 'bearer',
        user: { id: updated.id, email: updated.email, created_at: updated.created_at,
          email_confirmed_at: updated.email_confirmed_at, user_metadata: updated.raw_user_meta_data || {},
          app_metadata: { provider: updated.raw_user_meta_data?.provider || 'email', role: current.app_role } } });
    } catch {
      await client?.query('ROLLBACK').catch(() => {});
      return res.status(503).json({ error: 'Не удалось сохранить пароль. Повторите попытку.' });
    } finally { client?.release(); }
  });
}
