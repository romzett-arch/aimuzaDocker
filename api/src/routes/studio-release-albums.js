import { randomUUID } from 'node:crypto';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';

export function registerStudioReleaseAlbums(router, { cleanText, validUuid }) {
  router.post('/release-albums', requireAuth, async (req, res, next) => {
    const title = cleanText(req.body?.title, 100);
    const target = req.body?.albumId;
    const ids = Array.isArray(req.body?.trackIds) ? [...new Set(req.body.trackIds)] : [];
    const existing = target != null;
    if ((existing ? !validUuid(target) : !title) || ids.length < (existing ? 1 : 2) || ids.length > 100 || !ids.every(validUuid)) {
      return res.status(400).json({ error: existing ? 'Выберите альбом и от 1 до 100 релизов' : 'Укажите название альбома и выберите от 2 до 100 релизов' });
    }

    let client;
    try {
      client = await pool.connect();
      await client.query('BEGIN');
      const { rows } = await client.query(
        `SELECT t.id, t.release_album_id, t.release_album_name FROM public.tracks t
         WHERE t.user_id = $1 AND (t.id = ANY($2::uuid[]) OR t.release_album_id = $3)
           AND EXISTS (SELECT 1 FROM public.release_packages p WHERE p.track_id = t.id AND p.user_id = $1)
         ORDER BY t.id FOR UPDATE`, [req.user.id, ids, target ?? null],
      );
      const albumTrack = existing ? rows.find((row) => row.release_album_id === target.toLowerCase()) : null;
      const available = new Set(rows.map((row) => row.id));
      if (ids.some((id) => !available.has(id.toLowerCase())) || (existing && !albumTrack)) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Релиз или альбом недоступен. Обновите список.' });
      }
      const albumId = target ?? randomUUID();
      await client.query(
        'UPDATE public.tracks SET release_album_id = $1, release_album_name = $2 WHERE user_id = $3 AND id = ANY($4::uuid[])',
        [albumId, existing ? albumTrack.release_album_name : title, req.user.id, ids],
      );
      await client.query('COMMIT');
      return res.json({ albumId });
    } catch (error) {
      if (client) await client.query('ROLLBACK');
      next(error);
    } finally { client?.release(); }
  });
}
