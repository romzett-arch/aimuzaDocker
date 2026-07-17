/**
 * Storage Routes — замена Supabase Storage
 * Файлы: /opt/aimuza/data/uploads/
 *
 * GET    /storage/v1/bucket/:id     — конфиг бакета (allowed_mime_types)
 * POST   /storage/v1/object/:bucket/*path  — загрузка
 * PUT    /storage/v1/object/:bucket/*path  — upsert
 * GET    /storage/v1/object/public/:bucket/*path  — скачивание
 * DELETE /storage/v1/object/:bucket  — удаление (body: paths[])
 */
import { Router } from 'express';
import multer from 'multer';
import path from 'path';
import fs from 'fs';
import crypto from 'crypto';
import { pool } from '../db.js';

const router = Router();

const UPLOADS_DIR = process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads';
const UPLOADS_DIR_RESOLVED = path.resolve(UPLOADS_DIR);
const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const STORAGE_SIGNING_SECRET = process.env.JWT_SECRET;

// Создаём директорию если нет
function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

// A3: Path traversal protection — ensure path stays inside UPLOADS_DIR
function safePath(bucket, filePath) {
  const full = path.resolve(path.join(UPLOADS_DIR, bucket, filePath));
  if (full !== UPLOADS_DIR_RESOLVED && !full.startsWith(`${UPLOADS_DIR_RESOLVED}${path.sep}`)) {
    return null; // traversal attempt
  }
  return full;
}

function isStorageAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

function parseSilkPath(bucket, filePath) {
  if (bucket !== 'tracks') return null;
  const parts = String(filePath || '').split('/').filter(Boolean);
  if (parts[0] !== 'silk-releases' || parts.length < 4) return null;
  return { userId: parts[1], releaseId: parts[2] };
}

function parseGalleryPath(bucket, filePath) {
  if (bucket !== 'gallery') return null;
  const parts = String(filePath || '').split('/').filter(Boolean);
  if (parts.length < 3) return null;
  return { userId: parts[0], assetId: parts[1] };
}

async function assertGalleryPathAccess(req, bucket, filePath, requireExistingItem = false) {
  const galleryPath = parseGalleryPath(bucket, filePath);
  if (!galleryPath) return;
  requireStorageUser(req);
  if (!isStorageAdmin(req.user) && galleryPath.userId !== req.user.id) {
    const error = new Error('Gallery storage path does not belong to the authenticated user');
    error.status = 403;
    throw error;
  }
  if (requireExistingItem && !isStorageAdmin(req.user)) {
    const result = await pool.query(
      `SELECT 1 FROM public.gallery_items
       WHERE user_id = $1 AND storage_bucket = $2
         AND (storage_path = $3 OR thumbnail_storage_path = $3)`,
      [req.user.id, bucket, filePath],
    );
    if (result.rowCount !== 1) {
      const error = new Error('Gallery item not found');
      error.status = 404;
      throw error;
    }
  }
}

async function canReadGalleryObject(req, bucket, filePath) {
  if (!parseGalleryPath(bucket, filePath)) return true;
  if (isValidSignedStorageRequest(bucket, filePath, req.query)) return true;

  const result = await pool.query(
    `SELECT user_id, is_public, status, moderation_status
     FROM public.gallery_items
     WHERE storage_bucket = $1
       AND (storage_path = $2 OR thumbnail_storage_path = $2)
     LIMIT 1`,
    [bucket, filePath],
  );
  const item = result.rows[0];
  if (!item) return false;
  if (isStorageAdmin(req.user) || (req.user?.id && req.user.id === item.user_id)) return true;
  return item.is_public === true && item.status === 'ready' && item.moderation_status === 'approved';
}

async function isActiveSilkVotingAsset(bucket, filePath) {
  const silkPath = parseSilkPath(bucket, filePath);
  if (!silkPath) return false;

  const result = await pool.query(
    `SELECT 1
     FROM public.silk_release_assets asset
     JOIN public.silk_releases release ON release.id = asset.release_id
     JOIN public.tracks track ON track.id = release.source_track_id
     WHERE asset.storage_bucket = $1
       AND asset.storage_path = $2
       AND asset.asset_type IN ('reference_mp3', 'master_wav', 'cover_art')
       AND asset.validation_status = 'valid'
       AND release.id = $3
       AND release.user_id = $4
       AND release.status = 'voting'
       AND track.moderation_status = 'voting'
       AND track.voting_type = 'public'
       AND track.voting_result = 'pending'
       AND track.voting_ends_at > now()
     LIMIT 1`,
    [bucket, filePath, silkPath.releaseId, silkPath.userId],
  );

  return result.rowCount === 1;
}

async function assertSilkPathAccess(req, bucket, filePath) {
  const silkPath = parseSilkPath(bucket, filePath);
  if (!silkPath) return;
  requireStorageUser(req);
  if (isStorageAdmin(req.user)) return;
  if (silkPath.userId !== req.user.id) {
    const error = new Error('Storage path does not belong to the authenticated user');
    error.status = 403;
    throw error;
  }
  const result = await pool.query(
    'SELECT 1 FROM public.silk_releases WHERE id = $1 AND user_id = $2',
    [silkPath.releaseId, req.user.id],
  );
  if (result.rowCount !== 1) {
    const error = new Error('Release not found');
    error.status = 404;
    throw error;
  }
}

function requireStorageUser(req) {
  if (!req.user?.id || req.user.id === 'anon') {
    const error = new Error('Authentication required');
    error.status = 401;
    throw error;
  }
}

function signedStorageToken(bucket, filePath, expires) {
  return crypto
    .createHmac('sha256', STORAGE_SIGNING_SECRET)
    .update(`${bucket}\n${filePath}\n${expires}`)
    .digest('base64url');
}

function isValidSignedStorageRequest(bucket, filePath, query) {
  const expires = Number(query.expires);
  const token = typeof query.token === 'string' ? query.token : '';
  if (!Number.isFinite(expires) || expires <= Math.floor(Date.now() / 1000) || !token) return false;
  const expected = signedStorageToken(bucket, filePath, expires);
  const actualBuffer = Buffer.from(token);
  const expectedBuffer = Buffer.from(expected);
  return actualBuffer.length === expectedBuffer.length && crypto.timingSafeEqual(actualBuffer, expectedBuffer);
}

// Multer — принимаем файлы в память (any field name)
const upload = multer({
  limits: { fileSize: 1024 * 1024 * 1024 }, // 1GB for release masters
  storage: multer.memoryStorage(),
});

const ALLOWED_UPLOAD_EXTENSIONS = new Set([
  '.mp3', '.wav', '.ogg', '.flac', '.aac',
  '.mp4', '.webm', '.mov',
  '.jpg', '.jpeg', '.png', '.gif', '.webp',
  '.pdf', '.zip', '.json', '.txt', '.csv', '.xml', '.xlsx',
  '.html', // сертификаты депонирования (lyrics-deposit, track-deposit)
]);

function assertValidGalleryVideo(file, ext) {
  const galleryVideoTypes = new Set(['video/mp4', 'video/webm', 'video/quicktime']);
  const galleryVideoExtensions = new Set(['.mp4', '.webm', '.mov']);
  const isMp4Family = ['.mp4', '.mov'].includes(ext)
    && file.buffer.subarray(4, 12).toString('ascii').includes('ftyp');
  const isWebm = ext === '.webm'
    && file.buffer.subarray(0, 4).equals(Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  if (!galleryVideoTypes.has(file.mimetype) || !galleryVideoExtensions.has(ext) || (!isMp4Family && !isWebm)) {
    const error = new Error('Only valid MP4, MOV or WebM video files are allowed');
    error.status = 400;
    throw error;
  }
  if (file.size > 500 * 1024 * 1024) {
    const error = new Error('Gallery video exceeds the 500 MB limit');
    error.status = 413;
    throw error;
  }
}

function requireStorageAuth(req, res, next) {
  if (!req.user || !req.user.id || req.user.id === 'anon') {
    return res.status(401).json({ error: 'Authentication required', code: 'AUTH_REQUIRED' });
  }
  next();
}

// Bucket config (storage-js проверяет allowed_mime_types перед загрузкой)
router.get('/bucket/:bucketId', (req, res) => {
  const { bucketId } = req.params;
  const buckets = {
    certificates: {
      id: bucketId,
      name: bucketId,
      public: true,
      allowed_mime_types: ['text/html', 'text/html;charset=utf-8', 'application/pdf', 'application/octet-stream'],
      file_size_limit: 5242880,
    },
  };
  const config = buckets[bucketId] || {
    id: bucketId,
    name: bucketId,
    public: false,
    allowed_mime_types: null,
    file_size_limit: 1073741824,
  };
  res.json(config);
});

// ─── Signed download URL ────────────────────
// Must be registered before the generic POST /object/:bucket/* upload route.
router.post('/object/sign/:bucket/*', requireStorageAuth, async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0];
    await assertSilkPathAccess(req, bucket, filePath);
    await assertGalleryPathAccess(req, bucket, filePath, true);

    const requestedLifetime = Number(req.body?.expiresIn || 3600);
    const lifetime = Math.min(Math.max(Math.floor(requestedLifetime), 60), 3600);
    const expires = Math.floor(Date.now() / 1000) + lifetime;
    const token = signedStorageToken(bucket, filePath, expires);
    const encodedPath = filePath.split('/').map(encodeURIComponent).join('/');
    res.json({
      signedURL: `/object/public/${encodeURIComponent(bucket)}/${encodedPath}?expires=${expires}&token=${encodeURIComponent(token)}`,
    });
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Could not sign file URL' });
  }
});

// ─── Upload ─────────────────────────────────
router.post('/object/:bucket/*', requireStorageAuth, upload.any(), async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0] || req.body?.path;
    
    if (!bucket || !filePath) {
      return res.status(400).json({ error: 'Bucket and path required' });
    }

    await assertSilkPathAccess(req, bucket, filePath);
    await assertGalleryPathAccess(req, bucket, filePath);

    if (!/^[a-zA-Z0-9_-]+$/.test(bucket)) {
      return res.status(400).json({ error: 'Invalid bucket name' });
    }

    const ext = path.extname(filePath).toLowerCase();
    const isCertificatesBucket = bucket === 'certificates';
    const isAllowedExt = ALLOWED_UPLOAD_EXTENSIONS.has(ext) || isCertificatesBucket;
    if (ext && !isAllowedExt) {
      return res.status(400).json({ error: 'File type not allowed' });
    }

    const fullPath = safePath(bucket, filePath);
    if (!fullPath) {
      return res.status(400).json({ error: 'Invalid path' });
    }
    ensureDir(path.dirname(fullPath));
    
    // 1) multer parsed files (any field name)
    if (req.files && req.files.length > 0) {
      if (bucket === 'gallery') {
        assertValidGalleryVideo(req.files[0], ext);
      }
      fs.writeFileSync(fullPath, req.files[0].buffer);
    }
    // 2) raw binary body (Supabase client sends file as raw body with Content-Type header)
    else if (req.body && Buffer.isBuffer(req.body)) {
      fs.writeFileSync(fullPath, req.body);
    }
    // 3) ArrayBuffer or Blob passed as body
    else if (req.body && typeof req.body === 'object' && !Array.isArray(req.body)) {
      // Try to detect if body has data (non-JSON upload)
      const ct = req.headers['content-type'] || '';
      if (ct.startsWith('image/') || ct.startsWith('audio/') || ct.startsWith('video/') || ct === 'application/octet-stream') {
        // Body should be a buffer — express raw parser would handle this
        return res.status(400).json({ error: 'File body not readable. Check Content-Type.' });
      }
      return res.status(400).json({ error: 'No file provided' });
    }
    else {
      return res.status(400).json({ error: 'No file provided' });
    }

    res.json({
      Key: `${bucket}/${filePath}`,
      data: { path: `${bucket}/${filePath}` },
    });
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Upload failed' });
  }
});

// ─── Upload via PUT (upsert) ─────────────────
router.put('/object/:bucket/*', requireStorageAuth, upload.any(), async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0];
    
    if (!bucket || !filePath) {
      return res.status(400).json({ error: 'Bucket and path required' });
    }


    await assertSilkPathAccess(req, bucket, filePath);
    await assertGalleryPathAccess(req, bucket, filePath);

    const ext = path.extname(filePath).toLowerCase();
    const isCertificatesBucket = bucket === 'certificates';
    const isAllowedExt = ALLOWED_UPLOAD_EXTENSIONS.has(ext) || isCertificatesBucket;
    if (ext && !isAllowedExt) {
      return res.status(400).json({ error: 'File type not allowed' });
    }

    const fullPath = safePath(bucket, filePath);
    if (!fullPath) {
      return res.status(400).json({ error: 'Invalid path' });
    }
    ensureDir(path.dirname(fullPath));
    
    if (req.files && req.files.length > 0) {
      if (bucket === 'gallery') {
        assertValidGalleryVideo(req.files[0], ext);
      }
      fs.writeFileSync(fullPath, req.files[0].buffer);
    } else if (req.body && Buffer.isBuffer(req.body)) {
      fs.writeFileSync(fullPath, req.body);
    } else {
      return res.status(400).json({ error: 'No file provided' });
    }

    res.json({
      Key: `${bucket}/${filePath}`,
      data: { path: `${bucket}/${filePath}` },
    });
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message || 'Upload failed' });
  }
});

// ─── Public/signed download ─────────────────
router.get('/object/public/:bucket/*', async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0];
    if (
      parseSilkPath(bucket, filePath)
      && !isValidSignedStorageRequest(bucket, filePath, req.query)
      && !(await isActiveSilkVotingAsset(bucket, filePath))
    ) {
      return res.status(401).json({ error: 'A valid signed URL is required', code: 'SIGNED_URL_REQUIRED' });
    }
    if (!(await canReadGalleryObject(req, bucket, filePath))) {
      return res.status(401).json({ error: 'A valid signed URL is required', code: 'SIGNED_URL_REQUIRED' });
    }
    const fullPath = safePath(bucket, filePath);
    if (!fullPath) {
      return res.status(400).json({ error: 'Invalid path' });
    }

    if (!fs.existsSync(fullPath)) {
      return res.status(404).json({ error: 'Not found' });
    }

    // Определяем content-type
    const ext = path.extname(filePath).toLowerCase();
    const mimeTypes = {
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.mp4': 'video/mp4',
      '.webm': 'video/webm',
      '.mov': 'video/quicktime',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.svg': 'image/svg+xml',
      '.pdf': 'application/pdf',
      '.json': 'application/json',
      '.zip': 'application/zip',
      '.txt': 'text/plain; charset=utf-8',
      '.csv': 'text/csv; charset=utf-8',
      '.xml': 'application/xml',
      '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.html': 'text/html; charset=utf-8',
    };

    const mime = mimeTypes[ext] || 'application/octet-stream';
    res.set('Content-Type', mime);
    res.set('Cache-Control', ext === '.html' ? 'no-store, max-age=0' : 'public, max-age=86400');
    res.set('Cross-Origin-Resource-Policy', 'cross-origin');
    res.set('Access-Control-Allow-Origin', '*');
    res.set('X-Content-Type-Options', 'nosniff');
    if (ext === '.html') {
      res.set(
        'Content-Security-Policy',
        "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; object-src 'none'; " +
        "script-src 'none'; " +
        "style-src 'self' 'unsafe-inline'; " +
        "img-src 'self' data:; " +
        "font-src 'self' data:; " +
        "connect-src 'none'; " +
        "frame-src 'none';"
      );
    }
    if (ext === '.svg') {
      res.set('Content-Disposition', 'attachment');
      res.set('Content-Security-Policy', "default-src 'none'");
    }
    res.sendFile(fullPath);
  } catch (err) {
    res.status(500).json({ error: 'Download failed' });
  }
});

// ─── getPublicUrl ────────────────────────────
router.post('/object/public-url/:bucket/*', (req, res) => {
  const bucket = req.params.bucket;
  const filePath = req.params[0];
  res.json({
    publicUrl: `/storage/v1/object/public/${bucket}/${filePath}`,
  });
});

// ─── Delete ─────────────────────────────────
router.delete('/object/:bucket', requireStorageAuth, async (req, res) => {
  try {
    const bucket = req.params.bucket;
    let body = req.body;
    if (Buffer.isBuffer(body)) {
      try { body = JSON.parse(body.toString()); } catch { body = []; }
    }
    const paths = Array.isArray(body) ? body : (body?.prefixes || []);

    let deleted = 0;
    for (const p of paths) {
      if (typeof p !== 'string' || !p) continue;
      await assertSilkPathAccess(req, bucket, p);
      await assertGalleryPathAccess(req, bucket, p);
      const fullPath = safePath(bucket, p);
      if (fullPath && fs.existsSync(fullPath)) {
        fs.unlinkSync(fullPath);
        deleted++;
      }
    }

    res.json({ message: 'Deleted', deleted });
  } catch (err) {
    console.error('[Storage DELETE]', err.message);
    res.status(err.status || 500).json({ error: err.message || 'Delete failed' });
  }
});

export default router;
