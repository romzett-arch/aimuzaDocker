import { Router } from 'express';
import sharp from 'sharp';
import { pool } from '../db.js';
import { requireAuth, requireServiceRole } from '../middleware/auth.js';
import { distributionCoverResolution, formatDistributionCover, isPaidReleaseCover, loadPaidReleaseCover } from '../services/distribution-cover.js';
import { loadTrackCover } from '../services/release-cover-source.js';
import {
  completeImage, failImage, getGeneratedImage, getImageJob, imageGallery, imageHistory, reserveImage,
} from '../services/image-generation.js';

const router = Router();
const ratios = new Set(['1:1', '2:3', '3:2', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9']);
const resolutions = new Set(['1K', '2K', distributionCoverResolution]);
const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;
const isUuid = (value) => typeof value === 'string' && uuid.test(value);
const maxReferenceBytes = 5 * 1024 * 1024;
const maxOutputBytes = 16 * 1024 * 1024;

function imageType(bytes) {
  if (bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) return 'image/png';
  if (bytes.subarray(0, 3).equals(Buffer.from('ffd8ff', 'hex'))) return 'image/jpeg';
  if (bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return null;
}

async function parseInput(req) {
  if (!req.is('multipart/form-data')) return req.body ?? {};
  const form = await new Request('http://localhost', {
    method: 'POST', headers: { 'Content-Type': req.headers['content-type'] }, body: req.body,
  }).formData();
  const input = Object.fromEntries(form);
  input.price = Number(input.price);
  if (input.reference) {
    if (typeof input.reference === 'string' || input.reference.size > maxReferenceBytes) throw new Error('Invalid reference');
    const bytes = Buffer.from(await input.reference.arrayBuffer());
    if (!imageType(bytes)) throw new Error('Invalid reference');
    input.reference = bytes;
  }
  return input;
}

router.get('/generated-image/:id', requireAuth, async (req, res, next) => {
  try {
    const result = req.user.role === 'authenticated' && isUuid(req.params.id)
      && await getGeneratedImage(req.user.id, req.params.id);
    if (!result) return res.sendStatus(404);
    const ext = { 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/png': 'png' }[result.mime_type];
    const name = result.resolution === distributionCoverResolution ? 'cover_3000x3000.jpg' : `aimuza-${req.params.id}.${ext}`;
    return res.set('Cache-Control', 'private, no-store').attachment(name).type(result.mime_type).send(result.image);
  } catch (error) { next(error); }
});

router.post('/release-package-cover', requireServiceRole, async (req, res, next) => {
  try {
    const { user_id: userId, id, track_id: trackId } = req.body ?? {};
    const image = isUuid(userId) && isUuid(id) && isUuid(trackId) && await loadPaidReleaseCover(userId, id, trackId);
    if (!image) return res.sendStatus(404);
    return res.set('Cache-Control', 'private, no-store').type('image/jpeg').send(image);
  } catch (error) { next(error); }
});

// ─── RouterAI: баланс провайдера генерации картинок (только админы) ──────────
// Ключ провайдера живёт в env API-сервера, поэтому баланс админка получает
// этим эндпоинтом. Кэш на 60 секунд — админка не бьёт провайдера каждым
// открытием вкладки. Site URL отдаётся для ссылки в настройках.
const routerAiCache = { data: null, at: 0 };

async function fetchRouterJson(path, apiKey) {
  const response = await fetch(`https://routerai.ru/${path}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    redirect: 'error',
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`RouterAI HTTP ${response.status}`);
  }
  return response.json();
}

router.get('/routerai-credits', requireAuth, async (req, res, next) => {
  try {
    const role = String(req.user?.app_role || '').toLowerCase();
    const isAdmin = req.user?.role === 'service_role' || role === 'admin' || role === 'super_admin' || role === 'superadmin';
    if (!isAdmin) return res.status(403).json({ error: 'Forbidden', code: 'ADMIN_REQUIRED' });

    const payload = {
      available: true,
      site_url: 'https://routerai.ru',
      model: 'bytedance-seed/seedream-5-0-flash',
    };
    const now = Date.now();
    if (routerAiCache.data && now - routerAiCache.at < 60_000) {
      return res.json({ ...payload, ...routerAiCache.data });
    }
    const apiKey = process.env.ROUTERAI_IMAGE_API_KEY?.trim();
    if (!apiKey) return res.json({ ...payload, available: false });
    try {
      const [creditsRes, keyRes] = await Promise.all([
        fetchRouterJson('api/v1/credits', apiKey),
        fetchRouterJson('api/v1/key', apiKey),
      ]);
      const data = {
        credits: Number(creditsRes?.data?.credits) || null,
        usage_monthly: Number(keyRes?.data?.usage_monthly) || null,
        key_name: keyRes?.data?.name || null,
        checked_at: new Date().toISOString(),
      };
      routerAiCache.data = data;
      routerAiCache.at = now;
      return res.json({ ...payload, ...data });
    } catch (error) {
      console.warn('[routerai credits]', error.message);
      return res.json({ ...payload, available: false, error: 'PROVIDER_UNAVAILABLE' });
    }
  } catch (error) { next(error); }
});

async function requestImage({ prompt, ratio, resolution, reference }, apiKey) {
  const response = await fetch('https://routerai.ru/api/v1/images', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'bytedance-seed/seedream-5-0-flash', prompt, n: 1, aspect_ratio: ratio, size: resolution,
      ...(reference ? { input_references: [{ type: 'image_url', image_url: { url: reference } }] } : {}),
    }),
    redirect: 'error',
    signal: AbortSignal.timeout(110_000),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`RouterAI HTTP ${response.status}`);
  }
  const { data } = await response.json();
  const encoded = data?.[0]?.b64_json;
  if (typeof encoded !== 'string' || encoded.length > Math.ceil(maxOutputBytes / 3) * 4) {
    throw new Error('Invalid RouterAI response');
  }
  const bytes = Buffer.from(encoded, 'base64');
  const type = imageType(bytes);
  if (!type || bytes.length > maxOutputBytes) throw new Error('Invalid RouterAI image');
  return { bytes, type };
}

router.post('/generate-image', requireAuth, async (req, res, next) => {
  if (req.user.role !== 'authenticated') return res.status(403).json({ error: 'Forbidden' });
  res.set('Cache-Control', 'no-store');
  const userId = req.user.id;
  let input;
  try {
    input = await parseInput(req);
  } catch {
    return res.json({ problem: 'INVALID_REFERENCE' });
  }

  try {
    if (input.action === 'history') return res.json({ jobs: await imageHistory(userId) });
    if (input.action === 'gallery') {
      if (input.cursor != null && !isUuid(input.cursor)) return res.json({ problem: 'INVALID_INPUT' });
      return res.json(await imageGallery(userId, input.cursor ?? null));
    }
    if (input.action === 'status' && isUuid(input.id)) {
      const job = await getImageJob(userId, input.id);
      return res.json(job ? { job } : { problem: 'IMAGE_NOT_FOUND' });
    }
    if (input.action === 'image' || input.action === 'thumbnail') {
      const result = typeof input.id === 'string' && uuid.test(input.id) && await getGeneratedImage(userId, input.id);
      if (!result) return res.json({ problem: 'IMAGE_NOT_FOUND' });
      if (input.action === 'thumbnail') {
        const thumbnail = await sharp(result.image, { limitInputPixels: 20_000_000 })
          .autoOrient().resize(320, 320, { fit: 'inside', withoutEnlargement: true }).webp({ quality: 75 }).toBuffer();
        return res.json({ image: thumbnail.toString('base64'), mime_type: 'image/webp' });
      }
      return res.json({ image: result.image.toString('base64'), mime_type: result.mime_type });
    }

    if (input.action === 'prepare-cover') return res.json({ problem: 'COVER_GENERATION_REQUIRED' });
    if (input.trackId && (!isUuid(input.trackId) || input.reference)) return res.json({ problem: 'INVALID_REFERENCE' });
    if (input.referenceId && (!isUuid(input.referenceId) || input.trackId || input.reference)) {
      return res.json({ problem: 'INVALID_REFERENCE' });
    }
    if (input.reference && !req.is('multipart/form-data')) return res.json({ problem: 'INVALID_REFERENCE' });
    // Multipart form serialization expands line breaks to CRLF.
    const prompt = typeof input.prompt === 'string' ? input.prompt.replace(/\r\n?/g, '\n').trim() : '';
    if (!isUuid(input.id) || input.action !== 'generate' || !prompt || prompt.length > 2000 ||
        !ratios.has(input.ratio) || !resolutions.has(input.resolution) || !Number.isSafeInteger(input.price) ||
        (input.trackId && input.resolution !== distributionCoverResolution)) {
      return res.json({ problem: 'INVALID_INPUT' });
    }
    const apiKey = process.env.ROUTERAI_IMAGE_API_KEY?.trim();
    if (!apiKey) return res.json({ problem: 'UNAVAILABLE' });

    if (input.releaseTrackId !== undefined) {
      if (!isUuid(input.releaseTrackId) || input.resolution !== distributionCoverResolution ||
          (input.trackId && input.trackId !== input.releaseTrackId)) return res.json({ problem: 'INVALID_INPUT' });
      const track = await pool.query("SELECT 1 FROM public.tracks WHERE id=$1 AND user_id=$2 AND status='completed'", [input.releaseTrackId, userId]);
      if (!track.rowCount) return res.json({ problem: 'INVALID_INPUT' });
    }

    let reference;
    try {
      let bytes = input.trackId ? await loadTrackCover(input.trackId, req.get('authorization')) : input.reference;
      if (input.referenceId) {
        const source = await getGeneratedImage(userId, input.referenceId);
        if (!source?.image || (input.releaseTrackId && !isPaidReleaseCover(source, input.releaseTrackId.toLowerCase()))) {
          return res.json({ problem: 'INVALID_REFERENCE' });
        }
        bytes = await sharp(source.image, { limitInputPixels: 20_000_000 }).autoOrient()
          .resize(2048, 2048, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 90 }).toBuffer();
      }
      if (bytes) {
        const mime = imageType(bytes);
        if (!mime) return res.json({ problem: 'INVALID_REFERENCE' });
        reference = `data:${mime};base64,${bytes.toString('base64')}`;
      }
    } catch {
      return res.json({ problem: 'INVALID_REFERENCE' });
    }

    const isDistributionCover = input.resolution === distributionCoverResolution;
    const ratio = isDistributionCover ? '1:1' : input.ratio;
    const { job, isNew, problem } = await reserveImage(userId, { ...input, prompt, ratio });
    if (problem) return res.json({ problem });
    if (!isNew) return res.json({ job });

    try {
      const resolution = isDistributionCover ? '2K' : input.resolution;
      const { bytes, type } = await requestImage({ prompt, ratio, resolution, reference }, apiKey);
      const image = isDistributionCover ? await formatDistributionCover(bytes) : bytes;
      if (image.length > maxOutputBytes) throw new Error('Generated image exceeds size limit');
      const completed = await completeImage(userId, job.id, image, isDistributionCover ? 'image/jpeg' : type);
      return res.json(completed ? { job: completed } : { problem: 'GENERATION_FAILED' });
    } catch (error) {
      console.warn('[image generation]', job.id, error.message);
      await failImage(userId, job.id);
      return res.json({ problem: 'GENERATION_FAILED' });
    }
  } catch (error) {
    next(error);
  }
});

export default router;
