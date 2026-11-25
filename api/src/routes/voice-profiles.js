import { raw, Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { pool } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { normalizeRecording, readVoiceRecordingTicket, voiceEnabled, voiceMediaMode } from '../services/voice-provider.js';
import { runVoiceProfileWorker } from '../services/voice-profile-worker.js';
import { createStudioGeneration } from '../services/studio-generate.js';

const router = Router();
const fields = 'id, name, status, phrase, attempts, error_message AS "error", created_at AS "createdAt"';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function voiceUser(req, res, next) {
  if (req.user.role !== 'authenticated') return res.status(403).json({ error: 'Войдите в свой аккаунт' });
  if (!voiceEnabled() && req.method === 'POST') return res.status(503).json({ error: 'Создание голосов временно недоступно' });
  next();
}

const upload = [
  rateLimit({ windowMs: 60000, limit: 8, keyGenerator: req => req.user.id, legacyHeaders: false,
    message: { error: 'Слишком много загрузок. Попробуйте через минуту.' } }),
  raw({ type: 'application/octet-stream', limit: '24mb' }),
];

function inputError(message, status = 400) {
  return Object.assign(new Error(message), { status });
}

function recording(req) {
  if (!Buffer.isBuffer(req.body) || !req.body.length) throw inputError('Добавьте аудиозапись');
  return req.body;
}

async function transaction(work) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await work(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}

function handle(operation) {
  return async (req, res, next) => {
    try { await operation(req, res.set('Cache-Control', 'private, no-store')); }
    catch (error) {
      if (error.status && error.status < 600) return res.status(error.status).json({
        error: error.status === 413 ? 'Максимальный размер файла — 24 МБ' : error.message,
      });
      next(error);
    }
  };
}

router.get('/media', handle(async (req, res) => {
  const ticket = readVoiceRecordingTicket(req.query.ticket);
  if (!ticket) return res.sendStatus(404);
  const { rows } = await pool.query(`
    SELECT r.data FROM public.voice_profile_recordings r JOIN public.voice_profiles p ON p.id = r.profile_id
    WHERE r.profile_id = $1 AND r.kind = $2 AND r.expires_at > now() AND p.deleted_at IS NULL
      AND p.status NOT IN ('ready', 'failed')
      AND ($2 = 'source' OR (p.attempts = $3 AND p.status IN ('voice_dispatching', 'voice_pending')))
  `, [ticket.id, ticket.kind, ticket.attempt ?? null]);
  if (!rows[0]) return res.sendStatus(404);
  res.removeHeader('Content-Security-Policy');
  res.type('audio/mpeg').send(rows[0].data);
}));

router.use(requireAuth, voiceUser);

router.post('/generate', (req, res, next) => {
  req.voiceSongRequest = true;
  return createStudioGeneration(req, res, next);
});

router.get('/', handle(async (req, res) => {
  const { rows } = await pool.query(`
    SELECT ${fields} FROM public.voice_profiles
    WHERE user_id = $1 AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 20
  `, [req.user.id]);
  res.json({ enabled: voiceEnabled(), providerUpload: voiceMediaMode() === 'provider-upload', profiles: rows });
}));

router.post('/', upload, handle(async (req, res) => {
  const id = req.get('x-voice-request-id');
  if (!uuid.test(id ?? '')) throw inputError('Начните настройку голоса заново');
  const userId = req.user.id;
  const existing = await pool.query(`SELECT ${fields} FROM public.voice_profiles WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, [id, userId]);
  if (existing.rows[0]) return res.status(202).json(existing.rows[0]);
  let name;
  try { name = decodeURIComponent(req.get('x-voice-name') ?? '').trim(); } catch { name = ''; }
  if (!name || Array.from(name).length > 60) throw inputError('Укажите название голоса до 60 символов');
  if (req.get('x-voice-consent') !== 'own-voice') throw inputError('Подтвердите, что это ваш голос');
  const start = Number(req.get('x-voice-start'));
  const end = Number(req.get('x-voice-end'));
  if (!(start >= 0 && end <= 240 && end - start >= 9.99 && end - start <= 120)) {
    throw inputError('Выберите фрагмент длиной от 10 до 120 секунд');
  }
  const source = await normalizeRecording(recording(req), 'source', { start, end });
  const profile = await transaction(async client => {
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 318))', [userId]);
    const owner = await client.query(`
      SELECT id FROM auth.users WHERE id = $1 AND email_confirmed_at IS NOT NULL
        AND NOT (COALESCE(raw_user_meta_data, '{}'::jsonb) ? 'deleted_at') FOR SHARE
    `, [userId]);
    if (!owner.rowCount) throw inputError('Войдите в свой аккаунт', 403);
    const prior = await client.query(`SELECT ${fields} FROM public.voice_profiles WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, [id, userId]);
    if (prior.rows[0]) return prior.rows[0];
    const counts = await client.query(`
      SELECT count(*) FILTER (WHERE created_at > now() - interval '24 hours') AS daily,
        count(*) FILTER (WHERE deleted_at IS NULL AND status = 'ready') AS ready,
        count(*) FILTER (WHERE deleted_at IS NULL AND status NOT IN ('ready', 'failed')) AS active
      FROM public.voice_profiles WHERE user_id = $1
    `, [userId]);
    const { daily, ready, active } = counts.rows[0];
    if (Number(daily) >= 3 || Number(ready) >= 10 || Number(active) >= 1) {
      throw inputError(Number(active) ? 'Завершите текущую настройку голоса' :
        Number(ready) >= 10 ? 'Достигнут лимит в 10 голосов' : 'Достигнут суточный лимит создания голосов', 429);
    }
    const { rows } = await client.query(`
      INSERT INTO public.voice_profiles (id, user_id, name, source_start, source_end)
      VALUES ($1,$2,$3,0,$4) ON CONFLICT DO NOTHING RETURNING ${fields}
    `, [id, userId, name, source.duration]);
    if (!rows[0]) throw inputError('Начните настройку голоса заново', 409);
    await client.query("INSERT INTO public.voice_profile_recordings (profile_id, kind, data) VALUES ($1,'source',$2)", [id, source.data]);
    return rows[0];
  });
  res.status(202).json(profile);
  void runVoiceProfileWorker();
}));

router.post('/:id/verify', upload, handle(async (req, res) => {
  const { id } = req.params;
  const attempt = Number(req.get('x-voice-attempt'));
  if (!uuid.test(id) || !Number.isInteger(attempt) || attempt < 1 || attempt > 4) throw inputError('Проверка голоса недоступна');
  const userId = req.user.id;
  const read = async (client, lock = '') => (await client.query(`
    SELECT ${fields} FROM public.voice_profiles WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL ${lock}
  `, [id, userId])).rows[0];
  function needsRecording(profile) {
    if (!profile) throw inputError('Голос не найден', 404);
    if (profile.attempts === attempt) return false;
    if (profile.status !== 'verification_required' || profile.attempts + 1 !== attempt) {
      throw inputError('Состояние проверки изменилось. Откройте голос снова.', 409);
    }
    return true;
  }
  const current = await read(pool);
  if (!needsRecording(current)) return res.status(202).json(current);
  const verified = await normalizeRecording(recording(req), 'verification');
  if (verified.duration < 1) throw inputError('Запись слишком короткая. Запишите всю фразу.');
  const updated = await transaction(async client => {
    const profile = await read(client, 'FOR UPDATE');
    if (!needsRecording(profile)) return profile;
    await client.query(`
      INSERT INTO public.voice_profile_recordings (profile_id,kind,data) VALUES ($1,'verification',$2)
      ON CONFLICT (profile_id,kind) DO UPDATE SET data=EXCLUDED.data, expires_at=EXCLUDED.expires_at
    `, [id, verified.data]);
    return (await client.query(`
      UPDATE public.voice_profiles SET status='voice_queued', attempts=$2, error_message=NULL, voice_task_id=NULL,
        next_poll_at=now(), updated_at=now() WHERE id=$1 RETURNING ${fields}
    `, [id, attempt])).rows[0];
  });
  res.status(202).json(updated);
  void runVoiceProfileWorker();
}));

router.delete('/:id', handle(async (req, res) => {
  if (!uuid.test(req.params.id)) throw inputError('Голос не найден', 404);
  await transaction(async client => {
    const { rowCount } = await client.query(`
      UPDATE public.voice_profiles SET deleted_at=now(), phrase=NULL, phrase_task_id=NULL, voice_task_id=NULL, provider_voice_id=NULL
      WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL
    `, [req.params.id, req.user.id]);
    if (rowCount) await client.query('DELETE FROM public.voice_profile_recordings WHERE profile_id=$1', [req.params.id]);
  });
  res.sendStatus(204);
}));

export default router;
