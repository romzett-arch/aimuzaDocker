import rateLimit from 'express-rate-limit';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { needsNickname, normalizeNickname } from '../security/profile-onboarding.js';

export function registerProfileOnboarding(router, database = pool) {
  const limiter = rateLimit({ windowMs: 15 * 60000, limit: 40 });
  const read = async (client, id, lock = false) => (await client.query(`
    SELECT u.raw_user_meta_data, p.username FROM auth.users u
    JOIN public.profiles p ON p.user_id=u.id
    WHERE u.id=$1 AND NOT (u.raw_user_meta_data ? 'deleted_at')
    ${lock ? 'FOR UPDATE OF u,p' : ''}`, [id])).rows[0];
  router.get('/profile-onboarding', requireAuth, async (req, res, next) => {
    res.set('Cache-Control', 'no-store');
    try {
      const row = await read(database, req.user.id);
      if (!row) return res.status(404).json({ error: 'Профиль не найден' });
      res.json({ required: needsNickname(row.raw_user_meta_data, row.username) });
    } catch (error) { next(error); }
  });
  router.post('/profile-onboarding', requireAuth, limiter, async (req, res, next) => {
    res.set('Cache-Control', 'no-store');
    const username = normalizeNickname(req.body.username);
    if (!username) return res.status(422).json({ error: 'Введите от 3 до 30 символов: буквы, цифры, пробел, точку, дефис или подчёркивание.' });
    let client;
    try {
      client = await database.connect();
      await client.query('BEGIN');
      // Serialize claims of the same case-insensitive nickname across providers.
      await client.query('SELECT pg_advisory_xact_lock(hashtextextended(lower($1),0))', ['nickname:' + username]);
      const row = await read(client, req.user.id, true);
      if (!row) { await client.query('ROLLBACK'); return res.status(404).json({ error: 'Профиль не найден' }); }
      if (!needsNickname(row.raw_user_meta_data, row.username)) {
        await client.query('ROLLBACK'); return res.json({ required: false });
      }
      if ((await client.query('SELECT 1 FROM public.profiles WHERE lower(username)=lower($1) AND user_id<>$2', [username, req.user.id])).rowCount) {
        await client.query('ROLLBACK'); return res.status(409).json({ error: 'Этот псевдоним уже занят. Выберите другой.' });
      }
      await client.query('UPDATE public.profiles SET username=$2,display_name=$2,updated_at=now() WHERE user_id=$1', [req.user.id, username]);
      await client.query(`UPDATE auth.users SET raw_user_meta_data=raw_user_meta_data ||
        jsonb_build_object('username',$2::text,'display_name',$2::text,'nickname_required',false,'nickname_selected_at',now()),updated_at=now() WHERE id=$1`, [req.user.id, username]);
      await client.query('COMMIT');
      res.json({ required: false, username });
    } catch (error) {
      if (client) await client.query('ROLLBACK');
      if (error.code === '23505') return res.status(409).json({ error: 'Этот псевдоним уже занят. Выберите другой.' });
      next(error);
    } finally { client?.release(); }
  });
}
