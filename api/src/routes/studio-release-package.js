import { pool } from '../db.js';
import { getImageJob } from '../services/image-generation.js';
import { distributionCoverResolution } from '../services/distribution-cover.js';

const cleanText = (value, limit) => typeof value === 'string' ? value.trim().slice(0, limit) : '';
const validUuid = (value) => typeof value === 'string' && /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i.test(value);

export async function prepareStudioReleasePackage(req, res, next) {
  try {
    const trackId = cleanText(req.body?.trackId, 64);
    const title = cleanText(req.body?.title, 100);
    const performer = cleanText(req.body?.performer, 80);
    const author = cleanText(req.body?.author, 80);
    const genre = cleanText(req.body?.genre, 80);
    const hasLyrics = req.body?.hasLyrics === true;
    const includeDeposit = req.body?.includeDeposit === true;
    const moveToMyReleases = req.body?.moveToMyReleases !== false;
    const coverId = req.body?.coverId;
    if (!validUuid(trackId)) return res.status(400).json({ error: 'Некорректный идентификатор трека' });
    if (!title || !performer || !author || !genre) return res.status(400).json({ error: 'Заполните название, автора, исполнителя и жанр' });

    // Проверка тарифа идёт до любого изменения трека или списания за
    // депонирование — так же, как в рабочем пространстве сайта.
    const tier = await pool.query(
      'SELECT public.get_user_subscription_tier($1) AS tier',
      [req.user.id],
    );
    if (!['creator', 'pro', 'label'].includes(tier.rows[0]?.tier?.tier_key)) {
      return res.status(403).json({ error: 'Релиз-пакет доступен на тарифе «Музыкант» и выше' });
    }

    const track = await pool.query(
      "SELECT id FROM public.tracks WHERE id = $1 AND user_id = $2 AND status = 'completed'",
      [trackId, req.user.id],
    );
    if (!track.rows[0]) return res.status(404).json({ error: 'Готовый трек не найден' });

    if (coverId != null) {
      const cover = validUuid(coverId) && await getImageJob(req.user.id, coverId);
      if (cover?.status !== 'completed' || cover.resolution !== distributionCoverResolution || cover.mime_type !== 'image/jpeg') {
        return res.status(400).json({ error: 'Выбранная обложка релиза недоступна' });
      }
    }

    const denoUrl = process.env.DENO_FUNCTIONS_URL;
    const authorization = req.get('authorization');
    if (!denoUrl || !authorization) return res.status(503).json({ error: 'Сервис подготовки релиз-пакета временно недоступен' });

    // То же обновление карточки, которое сайт делает перед вызовом Edge Function.
    await pool.query(
      `UPDATE public.tracks
       SET title = $1, performer_name = $2, music_author = $3,
           lyrics_author = CASE WHEN $4 THEN $3 ELSE lyrics_author END
       WHERE id = $5 AND user_id = $6`,
      [title, performer, author, hasLyrics, trackId, req.user.id],
    );

    if (includeDeposit) {
      const deposited = await pool.query(
        "SELECT id FROM public.track_deposits WHERE track_id = $1 AND status = 'completed' LIMIT 1",
        [trackId],
      );
      if (!deposited.rows[0]) {
        const depositResponse = await fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/track-deposit`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authorization },
          body: JSON.stringify({
            trackId,
            method: 'blockchain',
            authorData: {
              performer_name: performer,
              music_author: author,
              lyrics_author: hasLyrics ? author : '',
            },
          }),
        });
        const depositResult = await depositResponse.json().catch(() => ({}));
        if (!depositResponse.ok) return res.status(depositResponse.status).json(depositResult);
      }
    }

    const response = await fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/generate-release-package`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: authorization },
      body: JSON.stringify({
        track_id: trackId,
        release_title: title,
        performer_name: performer,
        author_name: author,
        release_genre: genre,
        has_lyrics: hasLyrics,
        include_deposit: includeDeposit,
        move_to_my_releases: moveToMyReleases,
        cover_id: coverId,
        force_regenerate: true,
      }),
    });
    const result = await response.json().catch(() => ({}));
    if (response.ok && moveToMyReleases && typeof result.zip_url === 'string') {
      await pool.query(
        `UPDATE public.tracks
         SET is_in_my_releases = TRUE, moved_to_my_releases_at = NOW(),
             is_public = FALSE, is_release_candidate = FALSE
         WHERE id = $1 AND user_id = $2`,
        [trackId, req.user.id],
      );
    }
    return res.status(response.status).json(result);
  } catch (error) { next(error); }
}
