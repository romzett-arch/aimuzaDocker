import jwt from 'jsonwebtoken';

const audience = 'suno-voice-recording';
const path = '/functions/v1/voice-profiles';

const uploadEndpoint = 'https://sunoapiorg.redpandaai.co/api/file-stream-upload';

export function voiceMediaMode() {
  return process.env.SUNO_VOICE_MEDIA_MODE || 'signed-url';
}

export function voiceEnabled() {
  const mode = voiceMediaMode();
  const mediaAvailable = mode === 'provider-upload' || (mode === 'signed-url' && mediaOrigin());
  return process.env.SUNO_VOICE_ENABLED === 'true' &&
    Boolean(process.env.SUNO_API_KEY && mediaAvailable && process.env.FFMPEG_API_KEY && process.env.VOICE_FFMPEG_URL);
}

function mediaOrigin() {
  try {
    const origin = new URL(process.env.SUNO_VOICE_PUBLIC_URL || process.env.BASE_URL);
    if (origin.protocol === 'https:' && !origin.username && !origin.password && origin.hostname !== 'localhost') return origin.origin;
  } catch { /* A public HTTPS origin is required for provider media. */ }
  return null;
}

export function voiceRecordingUrl(profileId, kind, attempt) {
  const ticket = jwt.sign({ kind, attempt }, process.env.JWT_SECRET, {
    audience, subject: profileId, algorithm: 'HS256', expiresIn: '2h',
  });
  return `${mediaOrigin()}${path}/media?ticket=${encodeURIComponent(ticket)}`;
}

export function readVoiceRecordingTicket(ticket) {
  if (typeof ticket !== 'string' || ticket.length > 2048) return null;
  try {
    const payload = jwt.verify(ticket, process.env.JWT_SECRET, { audience, algorithms: ['HS256'] });
    if (typeof payload === 'object' && typeof payload.sub === 'string' &&
        /^[0-9a-f-]{36}$/i.test(payload.sub) && ['source', 'verification'].includes(payload.kind)) {
      return { id: payload.sub, kind: payload.kind, attempt: payload.attempt };
    }
  } catch { /* Expired or invalid capability. */ }
  return null;
}

async function callVoice(endpoint, { body, taskId } = {}) {
  const base = process.env.SUNO_VOICE_API_URL || 'https://api.sunoapi.org';
  const url = new URL(`/api/v1/voice/${endpoint}`, base);
  if (taskId) url.searchParams.set('taskId', taskId);
  const response = await fetch(url, {
    method: body ? 'POST' : 'GET',
    headers: { Authorization: `Bearer ${process.env.SUNO_API_KEY}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    redirect: 'error',
    signal: AbortSignal.timeout(15000),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok || result?.code !== 200 || !result.data) {
    throw new Error('Suno Voice request failed', { cause: result?.code || response.status });
  }
  return result.data;
}

async function providerRecordingUrl(job, kind, loadRecording) {
  if (voiceMediaMode() === 'signed-url') return voiceRecordingUrl(job.id, kind, job.attempts);

  const recording = await loadRecording();
  if (!recording?.length) throw new Error('Voice recording is missing');
  const name = crypto.randomUUID() + '.mp3';
  const form = new FormData();
  form.set('file', new Blob([recording], { type: 'audio/mpeg' }), name);
  form.set('fileName', name);
  form.set('uploadPath', 'aimuza-voice');
  const response = await fetch(uploadEndpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUNO_API_KEY}` },
    body: form,
    redirect: 'error',
    signal: AbortSignal.timeout(20000),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok || result?.code !== 200 || !result.data?.downloadUrl) {
    throw new Error('Suno voice recording upload failed', { cause: result?.code || response.status });
  }
  const link = new URL(result.data.downloadUrl);
  if (link.origin !== 'https://tempfile.redpandaai.co' || link.username || link.password) {
    throw new Error('Unexpected Suno upload URL');
  }
  return link.href;
}

export const voiceProvider = {
  prepare: async (job, loadRecording) => callVoice('validate', { body: {
    voiceUrl: await providerRecordingUrl(job, 'source', loadRecording),
    vocalStartS: Number(job.source_start),
    vocalEndS: Number(job.source_end),
    language: 'ru',
  } }),
  phrase: taskId => callVoice('validate-info', { taskId }),
  create: async (job, loadRecording) => callVoice('generate', { body: {
    taskId: job.phrase_task_id,
    verifyUrl: await providerRecordingUrl(job, 'verification', loadRecording),
    voiceName: job.name,
  } }),
  record: taskId => callVoice('record-info', { taskId }),
  available: async taskId => (await callVoice('check-voice', { body: { task_id: taskId } })).isAvailable === true,
};

export async function normalizeRecording(buffer, kind, range) {
  const limit = kind === 'source' ? 240 : 60;
  const url = new URL('/internal/voice-recording', process.env.VOICE_FFMPEG_URL);
  url.searchParams.set('limit', limit);
  if (range) {
    url.searchParams.set('start', range.start);
    url.searchParams.set('end', range.end);
  }
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'x-api-key': process.env.FFMPEG_API_KEY, 'Content-Type': 'application/octet-stream' },
    body: buffer,
    signal: AbortSignal.timeout(35000),
  });
  if (!response.ok) {
    const status = response.status === 400 ? 400 : 503;
    throw Object.assign(new Error(status === 400 ? 'Не удалось прочитать аудио. Проверьте файл и его длительность.' : 'Обработка аудио временно недоступна.'), { status });
  }
  const duration = Number(response.headers.get('x-audio-duration'));
  const data = Buffer.from(await response.arrayBuffer());
  if (!(duration > 0 && duration <= limit) || !data.length || data.length > 4 * 1024 * 1024) throw new Error('Invalid normalized audio');
  return { duration, data };
}
