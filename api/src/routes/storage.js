/**
 * Storage Routes — замена Supabase Storage
 * Файлы хранятся локально в /opt/aimuza/data/uploads/
 * 
 * POST   /storage/v1/object/:bucket/*path  — загрузка
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

// ─── Upload ─────────────────────────────────
router.post('/object/:bucket/*', upload.any(), async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0] || req.body?.path;
    
    if (!bucket || !filePath) {
      return res.status(400).json({ error: 'Bucket and path required' });
    }

    if (!/^[a-zA-Z0-9_-]+$/.test(bucket)) {
      return res.status(400).json({ error: 'Invalid bucket name' });
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
    console.error('[Storage Upload]', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Upload via PUT (upsert) ─────────────────
router.put('/object/:bucket/*', upload.any(), async (req, res) => {
  try {
    const bucket = req.params.bucket;
    const filePath = req.params[0];
    
    if (!bucket || !filePath) {
      return res.status(400).json({ error: 'Bucket and path required' });
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
    console.error('[Storage PUT]', err.message);
    res.status(500).json({ error: err.message });
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

    res.set('Content-Type', mimeTypes[ext] || 'application/octet-stream');
    res.set('Cache-Control', 'public, max-age=86400');
    // Сертификаты — предлагаем скачать при наличии ?download= в query
    if (bucket === 'certificates' && req.query.download) {
      const downloadName = req.query.download || path.basename(filePath);
      // RFC 5987: ASCII fallback + UTF-8 filename* для кириллицы (избегаем битых файлов)
      const asciiFallback = 'certificate.html';
      const encoded = encodeURIComponent(downloadName);
      res.set('Content-Disposition', `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encoded}`);
    }
    res.sendFile(fullPath);
  } catch (err) {
    console.error('[Storage Download]', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── getPublicUrl (для совместимости с supabase client) ─────
router.post('/object/public-url/:bucket/*', (req, res) => {
  const bucket = req.params.bucket;
  const filePath = req.params[0];
  res.json({
    publicUrl: `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`,
  });
});

// ─── Delete ─────────────────────────────────
router.delete('/object/:bucket', (req, res) => {
  try {
    const bucket = req.params.bucket;
    const paths = req.body?.prefixes || req.body || [];

    for (const p of paths) {
      const fullPath = safePath(bucket, typeof p === 'string' ? p : '');
      if (fullPath && fs.existsSync(fullPath)) {
        fs.unlinkSync(fullPath);
      }
    }

    res.json({ message: 'Deleted' });
  } catch (err) {
    console.error('[Storage Delete]', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
