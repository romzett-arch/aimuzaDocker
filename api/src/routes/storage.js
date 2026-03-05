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

const router = Router();

const UPLOADS_DIR = process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads';
const UPLOADS_DIR_RESOLVED = path.resolve(UPLOADS_DIR);
const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';

// Создаём директорию если нет
function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

// A3: Path traversal protection — ensure path stays inside UPLOADS_DIR
function safePath(bucket, filePath) {
  const full = path.resolve(path.join(UPLOADS_DIR, bucket, filePath));
  if (!full.startsWith(UPLOADS_DIR_RESOLVED)) {
    return null; // traversal attempt
  }
  return full;
}

// Multer — принимаем файлы в память (any field name)
const upload = multer({
  limits: { fileSize: 100 * 1024 * 1024 }, // 100MB
  storage: multer.memoryStorage(),
});

const ALLOWED_UPLOAD_EXTENSIONS = new Set([
  '.mp3', '.wav', '.ogg', '.flac', '.aac',
  '.mp4', '.webm',
  '.jpg', '.jpeg', '.png', '.gif', '.webp',
  '.pdf', '.zip', '.json',
  '.html', // сертификаты депонирования (lyrics-deposit, track-deposit)
]);

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
      allowed_mime_types: ['text/html', 'text/html;charset=utf-8', 'application/octet-stream'],
      file_size_limit: 5242880,
    },
  };
  const config = buckets[bucketId] || {
    id: bucketId,
    name: bucketId,
    public: false,
    allowed_mime_types: null,
    file_size_limit: 52428800,
  };
  res.json(config);
});

// ─── Upload ─────────────────────────────────
router.post('/object/:bucket/*', requireStorageAuth, upload.any(), async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0] || req.body?.path;
    
    if (!bucket || !filePath) {
      return res.status(400).json({ error: 'Bucket and path required' });
    }

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
    res.status(500).json({ error: 'Upload failed' });
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
    res.status(500).json({ error: 'Upload failed' });
  }
});

// ─── Public download ────────────────────────
router.get('/object/public/:bucket/*', (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0];
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
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.svg': 'image/svg+xml',
      '.pdf': 'application/pdf',
      '.json': 'application/json',
      '.zip': 'application/zip',
      '.html': 'text/html; charset=utf-8',
    };

    const mime = mimeTypes[ext] || 'application/octet-stream';
    res.set('Content-Type', mime);
    res.set('Cache-Control', 'public, max-age=86400');
    res.set('Cross-Origin-Resource-Policy', 'cross-origin');
    res.set('Access-Control-Allow-Origin', '*');
    res.set('X-Content-Type-Options', 'nosniff');
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
router.delete('/object/:bucket', requireStorageAuth, (req, res) => {
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
      const fullPath = safePath(bucket, p);
      if (fullPath && fs.existsSync(fullPath)) {
        fs.unlinkSync(fullPath);
        deleted++;
      }
    }

    res.json({ message: 'Deleted', deleted });
  } catch (err) {
    console.error('[Storage DELETE]', err.message);
    res.status(500).json({ error: 'Delete failed' });
  }
});

export default router;
