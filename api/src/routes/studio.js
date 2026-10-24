import { Router } from 'express';
import crypto from 'crypto';
import { pool, setJWTClaims } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { normalizeStudioGeneration as normalizeInput, studioSunoPayload } from '../services/studio-generation-input.js';

const router = Router();

const cleanText = (value, limit) => typeof value === 'string' ? value.trim().slice(0, limit) : '';
const validUuid = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const fingerprint = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const generationPolls = new Map();

async function userBootstrap(userId) {
  const [profile, tracks, releases, service, subscription, tier] = await Promise.all([
    pool.query('SELECT p.username, p.avatar_url, p.balance, u.email FROM auth.users u LEFT JOIN public.profiles p ON p.user_id = u.id WHERE u.id = $1', [userId]),
    pool.query("SELECT count(*)::integer AS total FROM public.tracks WHERE user_id = $1", [userId]),
    pool.query("SELECT count(*)::integer AS total FROM public.silk_releases WHERE user_id = $1", [userId]),
    pool.query("SELECT name, price_rub FROM public.addon_services WHERE name IN ('generate_music_v6', 'vocal_separation', 'generate_lyrics') AND is_active IS TRUE"),
    pool.query("SELECT status, current_period_end FROM public.user_subscriptions WHERE user_id = $1 AND status IN ('active', 'canceled') AND current_period_end > now() ORDER BY current_period_end DESC LIMIT 1", [userId]),
    pool.query('SELECT public.get_user_subscription_tier($1) AS tier', [userId]),
  ]);
  const profileRow = profile.rows[0] || {};
  return {
    id: userId,
    name: profileRow.username || 'Пользователь',
    email: profileRow.email || null,
    tariff: {
      key: tier.rows[0]?.tier?.tier_key || 'free',
      name: ({ free: 'Новичок', creator: 'Музыкант', pro: 'Артист', label: 'Лейбл' })[tier.rows[0]?.tier?.tier_key] || 'Новичок',
    },
    authed: true,
    balance: Number(profileRow.balance || 0),
    currency: 'RUB',
    generationPrice: Number(service.rows.find((row) => row.name === 'generate_music_v6')?.price_rub || 0),
    vocalSeparationPrice: Number(service.rows.find((row) => row.name === 'vocal_separation')?.price_rub || 0),
    lyricsGenerationPrice: Number(service.rows.find((row) => row.name === 'generate_lyrics')?.price_rub || 0),
    stats: { tracks: tracks.rows[0]?.total || 0, releases: releases.rows[0]?.total || 0 },
    subscription: subscription.rows[0] || null,
    canPrepareReleasePackage: ['creator', 'pro', 'label'].includes(tier.rows[0]?.tier?.tier_key),
  };
}

router.get('/bootstrap', requireAuth, async (req, res, next) => {
  try { res.json(await userBootstrap(req.user.id)); } catch (error) { next(error); }
});

router.delete('/tracks', requireAuth, async (req, res, next) => {
  const ids = Array.isArray(req.body?.ids) ? [...new Set(req.body.ids.filter(validUuid))].slice(0, 100) : [];
  if (!ids.length) return res.status(400).json({ error: 'Выберите хотя бы один трек' });
  try {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      // Exactly mirror the site: PostgreSQL owns cascading dependent rows.
      // The previous hand-maintained list of dependent tables made a bulk
      // delete fail as soon as a track gained a new related entity.
      const deleted = await client.query(
        'DELETE FROM public.tracks WHERE user_id = $1 AND id = ANY($2::uuid[]) RETURNING id',
        [req.user.id, ids],
      );
      const trackIds = deleted.rows.map((row) => row.id);
      if (!trackIds.length) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Выбранные треки не найдены' });
      }
      await client.query('COMMIT');
      res.json({ deleted: trackIds.length, skipped: ids.length - trackIds.length });
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
  } catch (error) { next(error); }
});

async function pollPendingGenerations(userId, authorization) {
  const denoUrl = process.env.DENO_FUNCTIONS_URL;
  if (!denoUrl || !authorization) return;
  const tasks = await pool.query(
    `SELECT DISTINCT generation_params->>'task_id' AS task_id
     FROM public.generation_logs
     WHERE user_id = $1 AND status IN ('pending', 'processing')
       AND COALESCE(generation_params->>'task_id', '') <> ''`, [userId],
  );
  const now = Date.now();
  for (const { task_id: taskId } of tasks.rows) {
    if (now - (generationPolls.get(taskId) || 0) < 10_000) continue;
    generationPolls.set(taskId, now);
    void fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/suno-check-status`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: authorization },
      body: JSON.stringify({ taskId }),
    }).catch(() => {});
  }
}

const separationPolls = new Map();
const separationPollsInFlight = new Set();
async function pollPendingSeparations(userId, authorization) {
  const denoUrl = process.env.DENO_FUNCTIONS_URL;
  if (!denoUrl || !authorization) return;
  const jobs = await pool.query(`SELECT DISTINCT s.track_id FROM public.audio_separations s
    JOIN public.tracks t ON t.id = s.track_id AND t.user_id = s.user_id
    WHERE s.user_id = $1 AND s.status IN ('pending', 'processing', 'finalizing')`, [userId]);
  const now = Date.now();
  for (const [id, time] of separationPolls) if (now - time > 300_000) separationPolls.delete(id);
  for (const { track_id: trackId } of jobs.rows) {
    if (separationPollsInFlight.has(trackId) || now - (separationPolls.get(trackId) || 0) < 30_000) continue;
    separationPolls.set(trackId, now);
    separationPollsInFlight.add(trackId);
    // Keep the library responsive while the shared callback copies audio files.
    void fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/audio-separation`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: authorization },
      body: JSON.stringify({ track_id: trackId, action: 'status' }), signal: AbortSignal.timeout(110_000),
    }).catch(() => {}).finally(() => separationPollsInFlight.delete(trackId));
  }
}

router.get('/tracks', requireAuth, async (req, res, next) => {
  try {
    await pollPendingGenerations(req.user.id, req.get('authorization'));
    await pollPendingSeparations(req.user.id, req.get('authorization'));
    const result = await pool.query(
      `SELECT t.id, t.title, t.description, t.lyrics, t.performer_name, t.music_author, t.lyrics_author, t.status, t.audio_url, t.cover_url, t.duration,
              t.created_at, t.updated_at,
              EXISTS (SELECT 1 FROM public.silk_releases r WHERE r.source_track_id = t.id AND r.user_id = t.user_id) AS has_release,
              (SELECT s.status FROM public.audio_separations s WHERE s.track_id = t.id ORDER BY s.created_at DESC LIMIT 1) AS vocal_separation_status,
              (SELECT s.result_urls FROM public.audio_separations s WHERE s.track_id = t.id ORDER BY s.created_at DESC LIMIT 1) AS vocal_separation_results
       FROM public.tracks t
       WHERE t.user_id = $1 AND COALESCE(t.is_in_my_releases, FALSE) = FALSE
       ORDER BY t.created_at DESC
       LIMIT 100`,
      [req.user.id],
    );
    res.json(result.rows.map((track) => ({
      id: track.id,
      title: track.title || 'Новый трек',
      prompt: track.description || '',
      lyrics: track.lyrics || null,
      styleTags: '[]',
      instrumental: !track.lyrics,
      status: track.status === 'pending' ? 'queued' : track.status,
      stage: track.status === 'completed' ? 'Готово' : track.status === 'failed' ? 'Ошибка' : 'Генерация',
      progress: track.status === 'completed' ? 100 : track.status === 'processing' ? 55 : 10,
      audioUrl: track.audio_url || null,
      coverUrl: track.cover_url || null,
      duration: Number(track.duration || 0),
      performerName: track.performer_name || null,
      musicAuthor: track.music_author || null,
      lyricsAuthor: track.lyrics_author || null,
      waveform: null,
      liked: false,
      plays: 0,
      featured: false,
      createdAt: track.created_at,
      updatedAt: track.updated_at,
      hasRelease: track.has_release,
      hasWav: false,
      wavOwned: false,
      vocalSeparationStatus: track.vocal_separation_status || null,
      vocalSeparationResults: track.vocal_separation_results || null,
    })));
  } catch (error) { next(error); }
});

// Studio only forwards the authenticated user to the same Deno operation used
// by the main site. Billing stays entirely in audio-separation.
router.post('/tracks/:trackId/separate-vocals', requireAuth, async (req, res, next) => {
  try {
    if (!validUuid(req.params.trackId)) return res.status(400).json({ error: 'Некорректный идентификатор трека' });
    const denoUrl = process.env.DENO_FUNCTIONS_URL;
    const authorization = req.get('authorization');
    if (!denoUrl || !authorization) return res.status(503).json({ error: 'Сервис разделения временно недоступен' });
    const response = await fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/audio-separation`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: authorization }, body: JSON.stringify({ track_id: req.params.trackId }),
    });
    const result = await response.json().catch(() => ({}));
    return res.status(response.status).json(result);
  } catch (error) { next(error); }
});

router.get('/releases', requireAuth, async (req, res, next) => {
  try {
    const result = await pool.query(
      `SELECT r.id, r.source_track_id, r.title, r.artist_name, r.genre, r.language, r.explicit_content,
              r.release_date, r.label_name, r.upc_code, r.status, r.created_at,
              t.id AS track_id, t.title AS track_title, t.cover_url AS track_cover_url, t.duration AS track_duration
       FROM public.silk_releases r
       LEFT JOIN public.tracks t ON t.id = r.source_track_id
       WHERE r.user_id = $1 ORDER BY r.created_at DESC LIMIT 50`, [req.user.id],
    );
    res.json(result.rows.map((row) => ({
      id: row.id, trackId: row.source_track_id, title: row.title, artist: row.artist_name,
      genre: row.genre || '', language: (row.language || 'ru').toUpperCase(), explicit: row.explicit_content,
      releaseDate: row.release_date, label: row.label_name || 'АИМУЗА', upc: row.upc_code,
      status: row.status, createdAt: row.created_at,
      track: row.track_id ? { id: row.track_id, title: row.track_title, coverUrl: row.track_cover_url, duration: Number(row.track_duration || 0) } : null,
    })));
  } catch (error) { next(error); }
});

// Релиз-пакеты — готовая серверная сборка файлов для дистрибуции. Studio не
// дублирует её: только запускает ту же Edge Function, что и основной сайт.
router.get('/release-packages', requireAuth, async (req, res, next) => {
  try {
    const result = await pool.query(
      `SELECT p.id, p.track_id, p.status, p.zip_url, p.error_message, p.created_at, p.updated_at,
              p.requested_title, p.requested_performer_name,
              t.title AS track_title, t.cover_url AS track_cover_url,
              t.release_album_id, t.release_album_name
       FROM public.release_packages p
       LEFT JOIN public.tracks t ON t.id = p.track_id
       WHERE p.user_id = $1
       ORDER BY p.updated_at DESC
       LIMIT 100`,
      [req.user.id],
    );
    res.json(result.rows.map((row) => ({
      id: row.id,
      trackId: row.track_id,
      status: row.status,
      zipUrl: row.zip_url,
      errorMessage: row.error_message,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      title: row.requested_title || row.track_title || 'Релиз-пакет',
      performer: row.requested_performer_name || null,
      coverUrl: row.track_cover_url || null,
      albumId: row.release_album_id || null,
      albumName: row.release_album_name || null,
    })));
  } catch (error) { next(error); }
});

router.get('/release-options/:trackId', requireAuth, async (req, res, next) => {
  if (!validUuid(req.params.trackId)) return res.status(400).json({ error: 'Некорректный идентификатор трека' });
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN READ ONLY');
    await setJWTClaims(client, req.user);
    const track = await client.query('SELECT id FROM public.tracks WHERE id = $1 AND user_id = $2', [req.params.trackId, req.user.id]);
    if (!track.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Трек не найден' });
    }
    const { rows: [row] } = await client.query(
      `SELECT public.get_user_subscription_tier($1) AS tier,
              public.check_deposit_limit($1) AS quota,
              (SELECT price FROM public.get_deposit_method_catalog() WHERE method = 'blockchain' AND available) AS base_price,
              EXISTS (SELECT 1 FROM public.track_deposits WHERE user_id = $1 AND track_id = $2 AND method = 'blockchain' AND status = 'completed') AS deposited`,
      [req.user.id, req.params.trackId],
    );
    if (row.quota?.error || row.base_price == null) throw new Error('Не удалось проверить стоимость депонирования');
    await client.query('COMMIT');
    res.json({
      canPrepare: ['creator', 'pro', 'label'].includes(row.tier?.tier_key),
      deposit: {
        price: row.deposited || row.quota?.is_free ? 0 : Number(row.base_price),
        alreadyDeposited: row.deposited,
        freeRemaining: Number(row.quota?.free_remaining || 0),
      },
    });
  } catch (error) {
    if (client) await client.query('ROLLBACK');
    next(error);
  } finally { client?.release(); }
});

// Same persisted album fields as the main site's My Releases. No new tables.
router.post('/release-albums', requireAuth, async (req, res, next) => {
  const title = cleanText(req.body?.title, 100);
  const ids = Array.isArray(req.body?.trackIds) ? [...new Set(req.body.trackIds)] : [];
  if (!title || ids.length < 2 || ids.length > 100 || !ids.every(validUuid)) {
    return res.status(400).json({ error: 'Укажите название альбома и выберите от 2 до 100 треков' });
  }
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const tracks = await client.query(
      `SELECT t.id FROM public.tracks t
       WHERE t.user_id = $1 AND t.id = ANY($2::uuid[])
         AND EXISTS (SELECT 1 FROM public.release_packages p WHERE p.track_id = t.id AND p.user_id = $1)
       ORDER BY t.id FOR UPDATE`, [req.user.id, ids],
    );
    if (tracks.rows.length !== ids.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Часть выбранных релизов недоступна. Обновите список.' });
    }
    const albumId = crypto.randomUUID();
    await client.query(
      'UPDATE public.tracks SET release_album_id = $1, release_album_name = $2 WHERE user_id = $3 AND id = ANY($4::uuid[])',
      [albumId, title, req.user.id, ids],
    );
    await client.query('COMMIT');
    res.json({ albumId });
  } catch (error) {
    if (client) await client.query('ROLLBACK');
    next(error);
  } finally { client?.release(); }
});

router.post('/release-packages', requireAuth, async (req, res, next) => {
  try {
    const trackId = cleanText(req.body?.trackId, 64);
    const title = cleanText(req.body?.title, 100);
    const performer = cleanText(req.body?.performer, 80);
    const author = cleanText(req.body?.author, 80);
    const genre = cleanText(req.body?.genre, 80);
    const hasLyrics = req.body?.hasLyrics === true;
    const includeDeposit = req.body?.includeDeposit === true;
    const moveToMyReleases = req.body?.moveToMyReleases !== false;
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
});

router.get('/transactions', requireAuth, async (req, res, next) => {
  try {
    const result = await pool.query(
      `SELECT id, amount, type, description, created_at FROM public.balance_transactions
       WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50`, [req.user.id],
    );
    res.json(result.rows.map((row) => ({
      id: row.id, amount: Number(row.amount), type: row.type, description: row.description || 'Операция с балансом', createdAt: row.created_at,
    })));
  } catch (error) { next(error); }
});

router.post('/releases/drafts', requireAuth, async (req, res, next) => {
  try {
    const trackId = cleanText(req.body?.trackId, 64);
    const title = cleanText(req.body?.title, 100);
    const artistName = cleanText(req.body?.artist, 80);
    const genre = cleanText(req.body?.genre, 80);
    const language = ['RU', 'EN', 'IN'].includes(req.body?.language) ? req.body.language.toLowerCase() : 'ru';
    if (!validUuid(trackId) || !title || !artistName) return res.status(400).json({ error: 'Заполните название, исполнителя и выберите готовый трек' });
    const track = await pool.query('SELECT id, title, audio_url FROM public.tracks WHERE id = $1 AND user_id = $2 AND status = $3', [trackId, req.user.id, 'completed']);
    if (!track.rows[0]?.audio_url) return res.status(400).json({ error: 'Для релиза нужен готовый трек' });
    const existing = await pool.query('SELECT id FROM public.silk_releases WHERE user_id = $1 AND source_track_id = $2 AND status <> $3 LIMIT 1', [req.user.id, trackId, 'archived']);
    if (existing.rows[0]) return res.status(409).json({ error: 'Черновик релиза для этого трека уже создан' });
    const release = await pool.query(
      `INSERT INTO public.silk_releases (user_id, source_track_id, status, title, artist_name, genre, language, explicit_content, music_author, lyrics_author, metadata)
       VALUES ($1,$2,'draft',$3,$4,$5,$6,$7,$4,$4,$8)
       RETURNING id, source_track_id, status, title, artist_name, genre, language, explicit_content, created_at`,
      [req.user.id, trackId, title, artistName, genre || null, language, req.body?.explicit === true, JSON.stringify({ created_from: 'studio' })],
    );
    res.status(201).json(release.rows[0]);
  } catch (error) { next(error); }
});

router.get('/generations/:requestId', requireAuth, async (req, res, next) => {
  try {
    if (!validUuid(req.params.requestId)) return res.status(400).json({ error: 'Некорректный идентификатор запроса' });
    const logs = await pool.query(
      `SELECT l.request_id, l.generation_params, l.status, t.id, t.title, t.status AS track_status, t.audio_url, t.cover_url, t.duration, t.error_message
       FROM public.generation_logs l JOIN public.tracks t ON t.id = l.track_id
       WHERE l.user_id = $1 AND l.request_id = $2 ORDER BY l.created_at ASC`, [req.user.id, req.params.requestId],
    );
    if (!logs.rows.length) return res.status(404).json({ error: 'Генерация не найдена' });
    const params = logs.rows[0].generation_params || {};
    res.json({ requestId: req.params.requestId, status: params.dispatch_state || logs.rows[0].status, taskId: params.task_id || null, tracks: logs.rows.map((row) => ({ ...row, generation_params: undefined })) });
  } catch (error) { next(error); }
});

router.post('/generations', requireAuth, async (req, res, next) => {
  const authorization = req.get('authorization');
  let client;
  try {
    const input = normalizeInput(req.body);
    const payloadHash = fingerprint({ ...input, requestId: undefined });
    client = await pool.connect();
    await client.query('BEGIN');
    await setJWTClaims(client, req.user);
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`studio:${req.user.id}:${input.requestId}`]);

    const prior = await client.query(
      `SELECT l.generation_params, t.id, t.title, t.status, t.audio_url, t.cover_url, t.duration
       FROM public.generation_logs l JOIN public.tracks t ON t.id = l.track_id
       WHERE l.user_id = $1 AND l.request_id = $2 ORDER BY l.created_at ASC`, [req.user.id, input.requestId],
    );
    if (prior.rows.length) {
      const params = prior.rows[0].generation_params || {};
      if (params.studio_payload_hash !== payloadHash) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'Этот идентификатор уже использован с другими параметрами' });
      }
      await client.query('COMMIT');
      return res.status(202).json({ requestId: input.requestId, status: params.dispatch_state || 'pending', taskId: params.task_id || null, tracks: prior.rows, replayed: true });
    }

    if (input.songIdeaId) {
      const acceptedIdea = await client.query(
        'SELECT id FROM public.song_idea_discoveries WHERE user_id = $1 AND idea_id = $2 AND accepted_at IS NOT NULL FOR SHARE',
        [req.user.id, input.songIdeaId],
      );
      if (!acceptedIdea.rows.length) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Сначала примите идею в своей библиотеке', code: 'SONG_IDEA_NOT_ACCEPTED' });
      }
    }

    let debit;
    try {
      debit = await client.query("SELECT * FROM public.debit_for_generation_v6($1, '{}'::uuid[], $2)", [req.user.id, `Музыкальная генерация: ${input.title || input.prompt.slice(0, 60)}`]);
    } catch (error) {
      await client.query('ROLLBACK');
      if (/Insufficient balance/i.test(error.message)) return res.status(402).json({ error: 'Недостаточно средств для генерации', code: 'INSUFFICIENT_FUNDS' });
      throw error;
    }
    const billing = debit.rows[0];
    const description = input.mode === 'custom' ? input.lyrics || input.style : input.prompt;
    const created = await client.query(
      `INSERT INTO public.tracks (user_id, title, description, lyrics, status, is_public)
       VALUES ($1,$2,$3,$4,'pending',false),($1,$2,$3,$4,'pending',false)
       RETURNING id, title, status, audio_url, cover_url, duration`,
      [req.user.id, input.title || 'Новый трек', description, input.instrumental ? null : input.lyrics || null],
    );
    const generationParams = { ...input, studio_payload_hash: payloadHash, dispatch_state: 'dispatching' };
    for (const track of created.rows) {
      await client.query(
        `INSERT INTO public.generation_logs (user_id, track_id, request_id, service_id, service_name, provider, provider_operation, provider_model, cost_rub, sale_price_rub, discount_rub, base_cost_credits, generation_params, status)
         VALUES ($1,$2,$3,$4,'generate_music_v6','sunoapi','generate','V6',$5,$6,$7,$8,$9,'pending')`,
        [req.user.id, track.id, input.requestId, billing.generation_service_id, Math.ceil(Number(billing.amount_debited) / 2), Math.ceil(Number(billing.generation_sale_price_rub) / 2), Math.ceil(Number(billing.discount_amount) / 2), Number(billing.generation_base_cost_credits || 0) / 2, generationParams],
      );
      await client.query(
        `INSERT INTO public.user_prompts (user_id, track_id, title, description, lyrics, is_public, price)
         VALUES ($1,$2,$3,$4,$5,false,0)`, [req.user.id, track.id, track.title, description, input.instrumental ? null : input.lyrics || null],
      );
    }
    if (input.songIdeaId) {
      await client.query('SELECT public.record_song_idea_generation($1, $2::uuid[])', [input.songIdeaId, created.rows.map((track) => track.id)]);
    }
    await client.query('COMMIT');
    client.release(); client = null;

    const denoUrl = process.env.DENO_FUNCTIONS_URL;
    if (!denoUrl || !authorization) throw new Error('Генератор временно недоступен');
    const run = await fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/suno-generate`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: authorization },
      body: JSON.stringify(studioSunoPayload(input, created.rows)),
    });
    const result = await run.json().catch(() => null);
    const taskId = result?.taskId || result?.task_id || null;
    const dispatchState = run.ok && taskId ? 'submitted' : 'unknown';
    await pool.query(`UPDATE public.generation_logs SET generation_params = generation_params || $1::jsonb WHERE user_id=$2 AND request_id=$3`, [JSON.stringify({ dispatch_state: dispatchState, task_id: taskId }), req.user.id, input.requestId]);
    if (!run.ok || !taskId) return res.status(202).json({ requestId: input.requestId, status: 'unknown', tracks: created.rows, amountDebited: Number(billing.amount_debited), newBalance: Number(billing.new_balance) });
    return res.status(202).json({ requestId: input.requestId, status: 'submitted', taskId, tracks: created.rows, amountDebited: Number(billing.amount_debited), newBalance: Number(billing.new_balance) });
  } catch (error) {
    if (client) { try { await client.query('ROLLBACK'); } catch {} client.release(); }
    next(error);
  }
});

export default router;
