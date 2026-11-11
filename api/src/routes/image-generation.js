import { Router } from 'express';
import sharp from 'sharp';
import { requireAuth, requireServiceRole } from '../middleware/auth.js';
import { distributionCoverResolution, prepareDistributionCover } from '../services/distribution-cover.js';
import { loadTrackCover } from '../services/release-cover-source.js';
import {
  completeImage, failImage, getGeneratedImage, getImageJob, imageGallery, imageHistory, reserveImage, savePreparedCover,
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
    const { user_id: userId, id } = req.body ?? {};
    const result = isUuid(userId) && isUuid(id) && await getGeneratedImage(userId, id);
    if (!result || result.resolution !== distributionCoverResolution || result.mime_type !== 'image/jpeg') {
      return res.sendStatus(404);
    }
    return res.set('Cache-Control', 'private, no-store').type(result.mime_type).send(result.image);
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

    const isMultipart = req.is('multipart/form-data');
    const prepare = input.action === 'prepare-cover';
    if (input.trackId && (!isUuid(input.trackId) || input.reference)) return res.json({ problem: 'INVALID_REFERENCE' });
    if (input.reference && !isMultipart) return res.json({ problem: 'INVALID_REFERENCE' });
    // Multipart form serialization expands line breaks to CRLF.
    const prompt = typeof input.prompt === 'string' ? input.prompt.replace(/\r\n?/g, '\n').trim() : '';
    if (!isUuid(input.id) || (!prepare && (input.action !== 'generate' || !prompt || prompt.length > 2000 ||
        !ratios.has(input.ratio) || !resolutions.has(input.resolution) || !Number.isSafeInteger(input.price) ||
        (input.trackId && input.resolution !== distributionCoverResolution)))) {
      return res.json({ problem: 'INVALID_INPUT' });
    }
    const apiKey = process.env.ROUTERAI_IMAGE_API_KEY?.trim();
    if (!apiKey && !prepare) return res.json({ problem: 'UNAVAILABLE' });

    let reference;
    try {
      const bytes = input.trackId ? await loadTrackCover(input.trackId, req.get('authorization')) : input.reference;
      if (bytes) {
        const mime = imageType(bytes);
        if (!mime) return res.json({ problem: 'INVALID_REFERENCE' });
        if (prepare) {
          const image = await prepareDistributionCover(bytes);
          return res.json({ job: await savePreparedCover(userId, input.id, image, distributionCoverResolution) });
        }
        reference = `data:${mime};base64,${bytes.toString('base64')}`;
      } else if (prepare) return res.json({ problem: 'INVALID_REFERENCE' });
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
      const image = isDistributionCover ? await prepareDistributionCover(bytes) : bytes;
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
