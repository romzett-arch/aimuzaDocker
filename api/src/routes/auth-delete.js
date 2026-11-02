import bcrypt from 'bcryptjs';
import crypto from 'node:crypto';
import rateLimit from 'express-rate-limit';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';

// Account closure is an authenticated, password-confirmed operation. Keep the
// pseudonymous ID for financial/copyright records instead of cascading them away.
export function registerAccountDeletion(router) {
  router.post('/delete-account', requireAuth, rateLimit({ windowMs: 15 * 60 * 1000, limit: 5, keyGenerator: req => req.user.id }), async (req, res, next) => {
    if (req.body?.confirmation !== 'УДАЛИТЬ' || typeof req.body?.password !== 'string' || req.body.password.length > 100) {
      return res.status(422).json({ error: 'Введите пароль и слово УДАЛИТЬ' });
    }
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { rows } = await client.query(`SELECT u.email,u.encrypted_password,u.raw_user_meta_data,u.is_super_admin,
        p.is_protected,p.avatar_url,p.cover_url FROM auth.users u JOIN public.profiles p ON p.user_id=u.id
        WHERE u.id=$1 FOR UPDATE OF u,p`, [req.user.id]);
      const user = rows[0];
      if (!user || !(await bcrypt.compare(req.body.password, user.encrypted_password || ''))) {
        await client.query('ROLLBACK');
        return res.status(403).json({ error: 'Неверный пароль' });
      }
      const roles = await client.query("SELECT 1 FROM public.user_roles WHERE user_id=$1 AND role::text IN ('admin','super_admin')", [req.user.id]);
      if (user.is_super_admin || user.is_protected || roles.rowCount) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'Сначала передайте административные полномочия другому аккаунту' });
      }
      const deletedEmail = `deleted-${req.user.id}@deleted.invalid`;
      const version = Number(user.raw_user_meta_data?.session_version || 0) + 1;
      await client.query(`UPDATE auth.users SET email=$2,encrypted_password=$3,email_confirmed_at=NULL,
        raw_user_meta_data=$4,updated_at=now(),last_sign_in_at=NULL WHERE id=$1`,
      [req.user.id, deletedEmail, await bcrypt.hash(crypto.randomBytes(32).toString('hex'), 12), JSON.stringify({ session_version: version, deleted_at: new Date().toISOString() })]);
      await client.query(`UPDATE public.profiles SET username=$2,display_name='Удалённый пользователь',email=NULL,
        avatar_url=NULL,cover_url=NULL,bio=NULL,social_links='{}',notification_settings='{}',email_unsubscribed=true,
        slug=$3,show_online_status=false,show_profile_stats=false,is_blocked=true,blocked_reason='account_deleted'
        WHERE user_id=$1`, [req.user.id, `deleted_${req.user.id.replaceAll('-', '')}`, `deleted-${req.user.id}`]);
      await client.query('DELETE FROM public.api_refresh_sessions WHERE user_id=$1', [req.user.id]);
      await client.query('DELETE FROM public.email_verifications WHERE user_id=$1 OR email=$2', [req.user.id, user.email]);
      await client.query(`UPDATE public.user_subscriptions SET auto_renew=false,
        status=CASE WHEN status='active' THEN 'canceled' ELSE status END,
        canceled_at=COALESCE(canceled_at,now()),updated_at=now() WHERE user_id=$1 AND (status='active' OR auto_renew)`, [req.user.id]);
      await client.query("UPDATE public.lyrics_generation_jobs SET status='failed',prompt='',error_message='account_deleted' WHERE user_id=$1 AND status='pending'", [req.user.id]);
      // Private creative history is explicitly removed only by account closure.
      await client.query('DELETE FROM public.generated_lyrics WHERE user_id=$1', [req.user.id]);
      await client.query('DELETE FROM public.user_prompts WHERE user_id=$1', [req.user.id]);
      await client.query('UPDATE public.tracks SET is_public=false WHERE user_id=$1', [req.user.id]);
      for (const url of [user.avatar_url, user.cover_url].filter(Boolean)) {
        await client.query('INSERT INTO public.media_cleanup_jobs(track_id,payload) VALUES($1,$2)', [req.user.id, { url }]);
      }
      await client.query('COMMIT');
      return res.json({ ok: true });
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      next(error);
    } finally { client.release(); }
  });
}
