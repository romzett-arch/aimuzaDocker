import { pool } from '../db.js';
import { voiceEnabled, voiceProvider } from './voice-provider.js';

const failed = new Set(['processing_validate_fail', 'fail']);
let running = false;

async function loadRecording(db, job, kind) {
  const { rows } = await db.query(`
    SELECT r.data FROM public.voice_profile_recordings r JOIN public.voice_profiles p ON p.id = r.profile_id
    WHERE r.profile_id = $1 AND r.kind = $2 AND r.expires_at > now()
      AND p.status = $3 AND p.attempts = $4 AND p.deleted_at IS NULL
  `, [job.id, kind, job.status, job.attempts]);
  return rows[0]?.data;
}

async function advance(job, provider, recording) {
  switch (job.status) {
    case 'phrase_queued': {
      const { taskId } = await provider.prepare(job, () => recording('source'));
      if (!taskId) throw new Error('Missing phrase task');
      return ['phrase_pending', 'phrase_task_id', taskId];
    }
    case 'phrase_pending': {
      const result = await provider.phrase(job.phrase_task_id);
      if (result.status === 'wait_validating' && typeof result.validateInfo === 'string' && result.validateInfo.trim()) {
        return ['verification_required', 'phrase', result.validateInfo.slice(0, 1000)];
      }
      if (failed.has(result.status)) return ['failed', 'error_message', 'Не удалось получить фразу. Создайте голос заново.'];
      break;
    }
    case 'voice_queued': {
      const { taskId } = await provider.create(job, () => recording('verification'));
      if (!taskId) throw new Error('Missing voice task');
      return ['voice_pending', 'voice_task_id', taskId];
    }
    case 'voice_pending': {
      const result = await provider.record(job.voice_task_id);
      if (result.status === 'success' && result.voiceId && await provider.available(job.voice_task_id)) {
        return ['ready', 'provider_voice_id', result.voiceId];
      }
      if (failed.has(result.status)) {
        return job.attempts < 4
          ? ['verification_required', 'error_message', 'Проверка не прошла. Запишите показанную фразу ещё раз.']
          : ['failed', 'error_message', 'Попытки проверки закончились. Создайте голос заново.'];
      }
      break;
    }
  }
  return null;
}

async function claimJobs(db) {
  const { rows } = await db.query(`
    WITH candidates AS (
      SELECT id, status FROM public.voice_profiles
      WHERE deleted_at IS NULL AND created_at > now() - interval '24 hours'
        AND status IN ('phrase_queued', 'phrase_pending', 'voice_queued', 'voice_pending')
        AND COALESCE(next_poll_at, created_at) <= now()
      ORDER BY COALESCE(next_poll_at, created_at) LIMIT 8 FOR UPDATE SKIP LOCKED
    )
    UPDATE public.voice_profiles p SET
      status = CASE c.status WHEN 'phrase_queued' THEN 'phrase_dispatching'
                            WHEN 'voice_queued' THEN 'voice_dispatching' ELSE c.status END,
      next_poll_at = now() + interval '1 minute'
    FROM candidates c WHERE p.id = c.id
    RETURNING p.*, c.status AS previous_status`);
  return rows;
}

async function settle(db, job, result) {
  const [status, column, value] = result;
  const { rowCount } = await db.query(`
    UPDATE public.voice_profiles SET status = $2, ${column} = $3, updated_at = now(),
      next_poll_at = CASE WHEN $2 IN ('phrase_pending', 'voice_pending') THEN now() + interval '5 seconds' END
    WHERE id = $1 AND deleted_at IS NULL AND status = $4 AND attempts = $5
  `, [job.id, status, value, job.status, job.attempts]);
  if (rowCount && status === 'ready') {
    await db.query('DELETE FROM public.voice_profile_recordings WHERE profile_id = $1', [job.id]);
  }
}

export async function processVoiceProfiles(db = pool, provider = voiceProvider) {
  await db.query('DELETE FROM public.voice_profile_recordings WHERE expires_at <= now()');
  await db.query(`
    UPDATE public.voice_profiles SET status = 'failed', updated_at = now(), phrase = NULL,
      error_message = CASE WHEN created_at <= now() - interval '24 hours'
        THEN 'Время настройки истекло. Создайте голос заново.'
        ELSE 'Не удалось подтвердить запуск обработки. Создайте голос заново.' END
    WHERE deleted_at IS NULL AND status NOT IN ('ready', 'failed')
      AND (created_at <= now() - interval '24 hours' OR
        (status IN ('phrase_dispatching', 'voice_dispatching') AND next_poll_at <= now()))
  `);
  if (!voiceEnabled() && provider === voiceProvider) return;
  await Promise.all((await claimJobs(db)).map(async job => {
    try {
      const result = await advance(
        { ...job, status: job.previous_status }, provider, kind => loadRecording(db, job, kind),
      );
      if (result) await settle(db, job, result);
      else await db.query(`
        UPDATE public.voice_profiles SET next_poll_at = now() + interval '8 seconds'
        WHERE id = $1 AND status = $2 AND attempts = $3 AND deleted_at IS NULL
      `, [job.id, job.status, job.attempts]);
    } catch (error) {
      console.warn('[voice profiles] background task', job.id, job.status, error.cause ?? error.code ?? error.name);
    }
  }));
}

export async function runVoiceProfileWorker() {
  if (running) return;
  running = true;
  try {
    await processVoiceProfiles();
  } catch (error) {
    console.warn('[voice profiles] worker', error.code ?? error.name);
  } finally {
    running = false;
  }
}

export function startVoiceProfileWorker() {
  void runVoiceProfileWorker();
  setInterval(() => void runVoiceProfileWorker(), 5000).unref();
}

export async function getAvailableVoice(db, userId, profileId) {
  const { rows } = await db.query(`
    SELECT provider_voice_id, voice_task_id FROM public.voice_profiles
    WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND status = 'ready' FOR SHARE
  `, [profileId, userId]);
  const profile = rows[0];
  if (!profile?.provider_voice_id || !profile.voice_task_id) {
    throw Object.assign(new Error('Выбранный голос недоступен'), { status: 400 });
  }
  if (!voiceEnabled() || !await voiceProvider.available(profile.voice_task_id).catch(() => false)) {
    throw Object.assign(new Error('Голос сейчас недоступен. Попробуйте позже.'), { status: 503 });
  }
  return profile.provider_voice_id;
}
