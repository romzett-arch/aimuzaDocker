const express = require('express');
const fs = require('fs');
const path = require('path');
const { requireApiKey } = require('./utils');
const { createAnalyzeHandler, createNormalizeHandler, createProcessWavHandler, createCleanMetadataHandler } = require('./handlers');

const app = express();
const PORT = process.env.PORT || 3001;
const HOST = process.env.HOST || '127.0.0.1';
const API_KEY = process.env.FFMPEG_API_KEY || '';
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');
const OUTPUT_DIR = process.env.OUTPUT_DIR || path.join(__dirname, 'output');

[UPLOAD_DIR, OUTPUT_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

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
  if (req.body && typeof req.body === 'string' && (req.path === '/analyze' || req.path === '/normalize' || req.path === '/clean-metadata' || req.path === '/process-wav')) {
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

app.use('/output', express.static(OUTPUT_DIR));

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

app.listen(PORT, HOST, () => {
  console.log(`FFmpeg microservice listening on ${HOST}:${PORT}`);
});
