const express = require('express');
const fs = require('fs');
const path = require('path');
const { requireApiKey } = require('./utils');
const { createAnalyzeHandler, createNormalizeHandler, createProcessWavHandler, createCleanMetadataHandler, createConvertFormatHandler } = require('./handlers');

const app = express();
const PORT = process.env.PORT || 3001;
const HOST = process.env.HOST || '127.0.0.1';
const API_KEY = process.env.FFMPEG_API_KEY || '';
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');
const OUTPUT_DIR = process.env.OUTPUT_DIR || path.join(__dirname, 'output');
const TEMP_MAX_AGE_MS = Number(process.env.FFMPEG_TEMP_MAX_AGE_MS) || 24 * 60 * 60 * 1000;
const DOWNLOAD_CACHE_MAX_AGE_MS = Number(process.env.FFMPEG_DOWNLOAD_CACHE_MAX_AGE_MS) || 30 * 24 * 60 * 60 * 1000;
const CLEANUP_INTERVAL_MS = Number(process.env.FFMPEG_CLEANUP_INTERVAL_MS) || 6 * 60 * 60 * 1000;

[UPLOAD_DIR, OUTPUT_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

function pruneDirectory(dir, maxAgeMs, shouldDelete = () => true) {
  const cutoff = Date.now() - maxAgeMs;
  let removed = 0;

  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isFile() || !shouldDelete(entry.name)) continue;
    const filePath = path.join(dir, entry.name);
    try {
      const stat = fs.statSync(filePath);
      if (stat.mtimeMs < cutoff) {
        fs.unlinkSync(filePath);
        removed++;
      }
    } catch (error) {
      console.warn(`[cleanup] Could not inspect/remove ${filePath}:`, error.message || String(error));
    }
  }

  return removed;
}

function cleanupFfmpegFiles() {
  const removedTemp = pruneDirectory(UPLOAD_DIR, TEMP_MAX_AGE_MS);
  const removedDownloads = pruneDirectory(
    OUTPUT_DIR,
    DOWNLOAD_CACHE_MAX_AGE_MS,
    (name) => name.startsWith('download_') || name.startsWith('.download_') || name.startsWith('distribution_') || name.startsWith('.distribution_')
  );
  if (removedTemp || removedDownloads) {
    console.log(`[cleanup] Removed temp=${removedTemp}, download_cache=${removedDownloads}`);
  }
}

cleanupFfmpegFiles();
setInterval(cleanupFfmpegFiles, CLEANUP_INTERVAL_MS).unref();

app.use((req, res, next) => {
  const ct = req.get('Content-Type');
  if (ct && /^application\/json\s*;/i.test(ct)) {
    req.headers['content-type'] = 'application/json';
  }
  next();
});

app.use(express.json({
  limit: '10mb',
  verify: (req, res, buf) => { req.rawBody = buf.length ? buf.toString('utf8') : ''; }
}));
app.use((err, req, res, next) => {
  if (err instanceof SyntaxError && err.status === 400) {
    const raw = (req.rawBody || '').slice(0, 500);
    console.error('[normalize] Invalid JSON body:', err.message, 'raw:', raw);
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Invalid JSON body',
      detail: err.message
    });
  }
  next(err);
});
app.use((req, res, next) => {
  if (req.body && typeof req.body === 'string' && (req.path === '/analyze' || req.path === '/normalize' || req.path === '/clean-metadata' || req.path === '/process-wav' || req.path === '/convert-format')) {
    const s = req.body.trim();
    if (s.startsWith('{')) {
      try { req.body = JSON.parse(s); } catch (_) {}
    }
  }
  next();
});

app.use('/analyze', requireApiKey(API_KEY));
app.post('/analyze', createAnalyzeHandler(UPLOAD_DIR));

app.use('/normalize', requireApiKey(API_KEY));
app.post('/normalize', createNormalizeHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/process-wav', requireApiKey(API_KEY));
app.post('/process-wav', createProcessWavHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/clean-metadata', requireApiKey(API_KEY));
app.post('/clean-metadata', createCleanMetadataHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/convert-format', requireApiKey(API_KEY));
app.post('/convert-format', createConvertFormatHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/output', express.static(OUTPUT_DIR));

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

app.listen(PORT, HOST, () => {
  console.log(`FFmpeg microservice listening on ${HOST}:${PORT}`);
});
