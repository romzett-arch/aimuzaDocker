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
const MAX_CONCURRENT_JOBS = Math.min(Math.max(Number(process.env.FFMPEG_MAX_CONCURRENT_JOBS) || 4, 1), 32);
const MAX_QUEUED_JOBS = Math.min(Math.max(Number(process.env.FFMPEG_MAX_QUEUED_JOBS) || 512, 1), 5000);

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
  const removedTransientOutputs = pruneDirectory(
    OUTPUT_DIR,
    TEMP_MAX_AGE_MS,
    (name) => name.startsWith('normalized_') || name.startsWith('.normalized_')
  );
  const removedDownloads = pruneDirectory(
    OUTPUT_DIR,
    DOWNLOAD_CACHE_MAX_AGE_MS,
    (name) => name.startsWith('download_') || name.startsWith('.download_') || name.startsWith('distribution_') || name.startsWith('.distribution_')
  );
  if (removedTemp || removedTransientOutputs || removedDownloads) {
    console.log(`[cleanup] Removed temp=${removedTemp}, transient_output=${removedTransientOutputs}, download_cache=${removedDownloads}`);
  }
}

function createConcurrencyLimiter(maxConcurrent, maxQueued) {
  let active = 0;
  const queue = [];

  const startNext = () => {
    while (active < maxConcurrent && queue.length > 0) {
      const nextJob = queue.shift();
      if (!nextJob.res.destroyed) nextJob.start();
    }
  };

  const middleware = (req, res, next) => {
    const start = () => {
      active += 1;
      let released = false;
      const release = () => {
        if (released) return;
        released = true;
        active = Math.max(0, active - 1);
        startNext();
      };
      res.once('finish', release);
      res.once('close', release);
      next();
    };

    if (active < maxConcurrent) return start();
    if (queue.length >= maxQueued) {
      res.set('Retry-After', '15');
      return res.status(503).json({
        error: 'FFmpeg queue is full',
        message: 'Audio processing capacity is temporarily full; retry later',
      });
    }

    let queuedJob;
    const removeQueuedJob = () => {
      const index = queue.indexOf(queuedJob);
      if (index >= 0) queue.splice(index, 1);
    };
    queuedJob = {
      req,
      res,
      start: () => {
        req.off('aborted', removeQueuedJob);
        res.off('close', removeQueuedJob);
        start();
      },
    };
    queue.push(queuedJob);
    req.once('aborted', removeQueuedJob);
    res.once('close', removeQueuedJob);
  };

  middleware.stats = () => ({ active, queued: queue.length, maxConcurrent, maxQueued });
  return middleware;
}

const heavyJobLimiter = createConcurrencyLimiter(MAX_CONCURRENT_JOBS, MAX_QUEUED_JOBS);

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
app.post('/analyze', heavyJobLimiter, createAnalyzeHandler(UPLOAD_DIR));

app.use('/normalize', requireApiKey(API_KEY));
app.post('/normalize', heavyJobLimiter, createNormalizeHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/process-wav', requireApiKey(API_KEY));
app.post('/process-wav', heavyJobLimiter, createProcessWavHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/clean-metadata', requireApiKey(API_KEY));
app.post('/clean-metadata', createCleanMetadataHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/convert-format', requireApiKey(API_KEY));
app.post('/convert-format', heavyJobLimiter, createConvertFormatHandler(UPLOAD_DIR, OUTPUT_DIR));

app.use('/output', express.static(OUTPUT_DIR));

app.get('/health', (req, res) => {
  res.set('X-FFmpeg-Active', String(heavyJobLimiter.stats().active));
  res.set('X-FFmpeg-Queued', String(heavyJobLimiter.stats().queued));
  res.status(200).send('OK');
});

app.listen(PORT, HOST, () => {
  console.log(`FFmpeg microservice listening on ${HOST}:${PORT}`);
  console.log(`FFmpeg concurrency limit=${MAX_CONCURRENT_JOBS}, queue limit=${MAX_QUEUED_JOBS}`);
});
