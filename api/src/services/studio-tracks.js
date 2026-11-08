import { Router } from 'express';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';

// ─── Studio · библиотека треков ──────────────────────────────────────────────
// Вынесено из routes/studio.js (лимит 350 строк): DTO трека и GET /tracks.
// reuseSettings — вход последней генерации из generation_logs для «Пересоздать
// по тем же настройкам»; у треков без лога поле null.

function reuseSettingsDto(params) {
  if (!params || typeof params !== 'object') return null;
  return {
    mode: params.mode === 'custom' ? 'custom' : 'simple',
    prompt: typeof params.prompt === 'string' ? params.prompt : '',
    title: typeof params.title === 'string' ? params.title : '',
    lyrics: typeof params.lyrics === 'string' ? params.lyrics : '',
    style: typeof params.style === 'string' ? params.style : '',
    negativeTags: typeof params.negativeTags === 'string' ? params.negativeTags : '',
    vocalGender: params.vocalGender === 'm' || params.vocalGender === 'f' ? params.vocalGender : null,
    tempo: Number.isInteger(params.tempo) && params.tempo > 0 ? params.tempo : 0,
    duration: Number.isInteger(params.duration) && params.duration >= 10 ? params.duration : 0,
    instrumental: params.instrumental === true,
  };
}

function studioTrackDto(track) {
  const params = track.generation_params;
  return {
    id: track.id,
    title: track.title || 'Новый трек',
    prompt: track.description || '',
    lyrics: track.lyrics || null,
    styleTags: '[]',
    instrumental: params?.instrumental === true,
    reuseSettings: reuseSettingsDto(params),
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
    listened: track.listened,
    hasWav: false,
    wavOwned: false,
    vocalSeparationStatus: track.vocal_separation_status || null,
    vocalSeparationResults: track.vocal_separation_results || null,
  };
}

// pollPendingGenerations/pollPendingSeparations передаются из routes/studio.js,
// чтобы не создавать циклический импорт.
export function createStudioTracksRouter({ pollPendingGenerations, pollPendingSeparations }) {
  const router = Router();

  router.get('/tracks', requireAuth, async (req, res, next) => {
    try {
      await pollPendingGenerations(req.user.id, req.get('authorization'));
      await pollPendingSeparations(req.user.id, req.get('authorization'));
      const result = await pool.query(
        `SELECT (SELECT g.generation_params FROM public.generation_logs g WHERE g.track_id = t.id ORDER BY g.created_at DESC LIMIT 1) AS generation_params, t.id, t.title, t.description, t.lyrics, t.performer_name, t.music_author, t.lyrics_author, t.status, t.audio_url, t.cover_url, t.duration,
              t.created_at, t.updated_at,
              EXISTS (SELECT 1 FROM public.user_listened_tracks l WHERE l.track_id = t.id AND l.user_id = $1) AS listened,
              EXISTS (SELECT 1 FROM public.silk_releases r WHERE r.source_track_id = t.id AND r.user_id = t.user_id) AS has_release,
              (SELECT s.status FROM public.audio_separations s WHERE s.track_id = t.id ORDER BY s.created_at DESC LIMIT 1) AS vocal_separation_status,
              (SELECT s.result_urls FROM public.audio_separations s WHERE s.track_id = t.id ORDER BY s.created_at DESC LIMIT 1) AS vocal_separation_results
       FROM public.tracks t
       WHERE t.user_id = $1 AND COALESCE(t.is_in_my_releases, FALSE) = FALSE
       ORDER BY t.created_at DESC
       LIMIT 100`,
        [req.user.id],
      );
      res.json(result.rows.map(studioTrackDto));
    } catch (error) { next(error); }
  });

  return router;
}
