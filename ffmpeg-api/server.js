const express = require('express');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const fetch = require('node-fetch');

function execFileAsync(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, opts, (err, stdout, stderr) => {
      if (err) reject(Object.assign(err, { stdout, stderr }));
      else resolve({ stdout, stderr });
    });
  });
}

const app = express();
const PORT = process.env.PORT || 3001;
const HOST = process.env.HOST || '127.0.0.1';
const API_KEY = process.env.FFMPEG_API_KEY || '';
const UPLOAD_DIR = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');
const OUTPUT_DIR = process.env.OUTPUT_DIR || path.join(__dirname, 'output');

[UPLOAD_DIR, OUTPUT_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

// Фикс 415: body-parser выбрасывает "unsupported charset UTF-8" при Content-Type: application/json; charset=UTF-8
// Нормализуем заголовок до application/json до парсинга тела
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
  if (req.body && typeof req.body === 'string' && (req.path === '/normalize' || req.path === '/clean-metadata' || req.path === '/analyze')) {
    const s = req.body.trim();
    if (s.startsWith('{')) {
      try { req.body = JSON.parse(s); } catch (_) {}
    }
  }
  next();
});

function requireApiKey(req, res, next) {
  if (!API_KEY) return next();
  const auth = req.headers['authorization'];
  const bearerKey = auth?.startsWith('Bearer ') ? auth.slice(7) : null;
  const key = req.headers['x-api-key'] || req.query.api_key || bearerKey;
  if (key !== API_KEY) {
    return res.status(401).json({ error: 'Invalid or missing API key' });
  }
  next();
}

function fetchAudio(req, audio_url, inputFile) {
  const fetchHeaders = {
    'User-Agent': 'FFmpeg-Microservice/1.0 (aimuza.ru)',
    'Accept': 'application/octet-stream,*/*'
  };
  const isPublicUrl = /\/object\/public\//.test(audio_url);
  if (!isPublicUrl && req.headers.authorization) {
    fetchHeaders['Authorization'] = req.headers.authorization;
  }
  const FETCH_TIMEOUT_MS = 120000;
  const opts = { redirect: 'follow', headers: fetchHeaders };
  const fetchPromise = fetch(audio_url, opts)
    .then(r => {
      if (!r.ok) {
        console.error('[fetchAudio] failed:', r.status, r.statusText, 'url:', audio_url.slice(0, 120));
        const err = new Error(`Fetch ${r.status} ${r.statusText}`);
        err.status = r.status;
        throw err;
      }
      return r.buffer();
    })
    .then(buffer => fs.writeFileSync(inputFile, buffer));
  const timeoutPromise = new Promise((_, reject) =>
    setTimeout(() => reject(new Error('Download timeout (120s)')), FETCH_TIMEOUT_MS)
  );
  return Promise.race([fetchPromise, timeoutPromise]);
}

// POST /analyze — анализ аудио (LUFS, format, streams) для process-master-audio
app.use('/analyze', requireApiKey);
app.post('/analyze', async (req, res) => {
  const body = req.body;
  if (!body || typeof body !== 'object') {
    return res.status(400).json({ error: 'Bad Request', message: 'Body must be JSON with audio_url' });
  }
  const audio_url = body.audio_url;
  if (typeof audio_url !== 'string' || !audio_url.trim()) {
    return res.status(400).json({ error: 'Bad Request', message: 'audio_url is required (string)' });
  }

  const ext = path.extname(new URL(audio_url).pathname) || '.wav';
  const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const inputFile = path.join(UPLOAD_DIR, `analyze_in_${suffix}${ext}`);

  try {
    await fetchAudio(req, audio_url, inputFile);
  } catch (e) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Failed to download audio: ' + (e.message || String(e)),
      details: e.status === 403 ? 'Access denied' : undefined
    });
  }

  let probe = null;
  let lufsAnalysis = null;

  try {
    const { stdout: probeOut } = await execFileAsync('ffprobe', [
      '-v', 'quiet', '-print_format', 'json',
      '-show_format', '-show_streams',
      inputFile
    ], { timeout: 30000 });
    probe = JSON.parse(probeOut || '{}');
  } catch (e) {
    try { fs.unlinkSync(inputFile); } catch (_) {}
    return res.status(500).json({
      error: 'Analysis failed',
      message: 'ffprobe failed: ' + (e.message || String(e))
    });
  }

  try {
    const { stderr } = await execFileAsync('ffmpeg', [
      '-i', inputFile,
      '-af', 'loudnorm=I=-14:TP=-1:LRA=11:print_format=json',
      '-f', 'null', '-'
    ], { timeout: 120000 });
    const raw = (stderr || '').replace(/\r/g, '');
    const start = raw.indexOf('{');
    if (start !== -1 && raw.includes('input_i')) {
      let depth = 0, end = start;
      for (let i = start; i < raw.length; i++) {
        if (raw[i] === '{') depth++;
        else if (raw[i] === '}') { depth--; if (depth === 0) { end = i + 1; break; } }
      }
      lufsAnalysis = JSON.parse(raw.slice(start, end));
    }
  } catch (e) {
    try { fs.unlinkSync(inputFile); } catch (_) {}
    return res.status(500).json({
      error: 'Analysis failed',
      message: 'Loudnorm analysis failed: ' + (e.message || String(e))
    });
  }

  try { fs.unlinkSync(inputFile); } catch (_) {}

  const audioStream = (probe.streams || []).find(s => s.codec_type === 'audio') || {};
  const formatInfo = probe.format || {};
  const sampleRate = parseInt(audioStream.sample_rate) || 44100;
  const bitDepth = audioStream.bits_per_sample || audioStream.bits_per_raw_sample || 16;
  const channels = audioStream.channels || 2;
  const duration = parseFloat(formatInfo.duration) || 0;
  const formatName = (formatInfo.format_name || 'unknown').split(',')[0];

  const integrated = lufsAnalysis ? parseFloat(lufsAnalysis.input_i) : -16;
  const truePeak = lufsAnalysis ? parseFloat(lufsAnalysis.input_tp) : -1;
  const range = lufsAnalysis ? parseFloat(lufsAnalysis.input_lra) : 8;

  const response = {
    streams: [{
      codec_type: 'audio',
      sample_rate: String(sampleRate),
      bits_per_sample: bitDepth,
      channels
    }],
    format: {
      duration: String(duration),
      format_name: formatName
    },
    lufs: {
      integrated,
      true_peak: truePeak,
      range
    },
    spectrum: { high_freq_cutoff: 20000 }
  };

  return res.json(response);
});

app.use('/normalize', requireApiKey);
app.post('/normalize', async (req, res) => {
  const body = req.body;
  if (!body || typeof body !== 'object') {
    return res.status(400).json({ error: 'Bad Request', message: 'Body must be JSON with audio_url' });
  }
  const audio_url = body.audio_url;
  if (typeof audio_url !== 'string' || !audio_url.trim()) {
    return res.status(400).json({ error: 'Bad Request', message: 'audio_url is required (string)' });
  }
  let target_lufs = body.target_lufs;
  if (typeof target_lufs === 'number' && !isNaN(target_lufs)) { /* keep */ }
  else if (typeof target_lufs === 'string') { target_lufs = parseFloat(target_lufs); }
  else { target_lufs = -14; }
  if (typeof target_lufs !== 'number' || isNaN(target_lufs)) target_lufs = -14;
  const strip_metadata = body.strip_metadata !== false;
  const brand_metadata = body.brand_metadata !== false;
  const metadata = body.metadata && typeof body.metadata === 'object' && !Array.isArray(body.metadata) ? body.metadata : {};

  const ext = path.extname(new URL(audio_url).pathname) || '.mp3';
  const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const inputFile = path.join(UPLOAD_DIR, `norm_in_${suffix}${ext}`);
  const outName = `normalized_${suffix}.mp3`;
  const outputFile = path.join(OUTPUT_DIR, outName);

  try {
    await fetchAudio(req, audio_url, inputFile);
  } catch (e) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Failed to download audio: ' + (e.message || String(e)),
      details: e.status === 403 ? 'Access denied (e.g. Supabase: check bucket is public or send Authorization)' : undefined
    });
  }

  let analysis = null;
  try {
    const { stderr } = await execFileAsync('ffmpeg', [
      '-i', inputFile,
      '-af', `loudnorm=I=${target_lufs}:TP=-1:LRA=11:print_format=json`,
      '-f', 'null', '-'
    ], { timeout: 120000 });
    const raw = (stderr || '').replace(/\r/g, '');
    const start = raw.indexOf('{');
    if (start !== -1 && raw.includes('input_i')) {
      let depth = 0, end = start;
      for (let i = start; i < raw.length; i++) {
        if (raw[i] === '{') depth++;
        else if (raw[i] === '}') { depth--; if (depth === 0) { end = i + 1; break; } }
      }
      analysis = JSON.parse(raw.slice(start, end));
    }
  } catch (e) {
    try { fs.unlinkSync(inputFile); } catch (_) {}
    return res.status(500).json({
      error: 'Analysis failed',
      message: 'Loudnorm analysis failed: ' + (e.message || String(e))
    });
  }

  if (!analysis || analysis.input_i === undefined) {
    try { fs.unlinkSync(inputFile); } catch (_) {}
    return res.status(500).json({
      error: 'Analysis failed',
      message: 'Could not parse loudnorm JSON from ffmpeg output'
    });
  }

  const filter = `loudnorm=I=${target_lufs}:TP=-1:LRA=11:measured_I=${analysis.input_i}:measured_TP=${analysis.input_tp}:measured_LRA=${analysis.input_lra}:measured_thresh=${analysis.input_thresh}:offset=${analysis.target_offset}:linear=true`;
  const args = ['-i', inputFile, '-af', filter];
  if (strip_metadata) args.push('-map_metadata', '-1');
  args.push('-id3v2_version', '3');
  if (brand_metadata && Object.keys(metadata).length) {
    for (const [k, v] of Object.entries(metadata)) {
      if (v != null && v !== '') args.push('-metadata', `${String(k)}=${String(v)}`);
    }
  }
  args.push('-ar', '44100', '-y', outputFile);

  return new Promise((resolve) => {
    execFile('ffmpeg', args, { timeout: 180000 }, (err, stdout, stderr) => {
      try { fs.unlinkSync(inputFile); } catch (_) {}
      if (err) {
        try { fs.unlinkSync(outputFile); } catch (_) {}
        return resolve(res.status(500).json({
          error: 'Normalization failed',
          message: 'FFmpeg: ' + (stderr || err.message || String(err))
        }));
      }
      const baseUrl = process.env.BASE_URL || 'https://aimuza.ru/api/ffmpeg';
      const output_url = `${baseUrl}/output/${outName}`;
      const normalized_url = output_url;
      const original_lufs = parseFloat(analysis.input_i);
      const normalized_lufs = target_lufs;
      const peak_before = parseFloat(analysis.input_tp);
      const peak_after = parseFloat(analysis.output_tp);
      return resolve(res.json({
        output_url,
        normalized_url,
        original_lufs,
        normalized_lufs,
        peak_before: isNaN(peak_before) ? undefined : peak_before,
        peak_after: isNaN(peak_after) ? undefined : peak_after
      }));
    });
  });
});

app.use('/clean-metadata', requireApiKey);
app.post('/clean-metadata', async (req, res) => {
  let body = req.body;
  if (!body || typeof body !== 'object') {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Body must be JSON object with audio_url and metadata'
    });
  }
  const { audio_url, metadata } = body;
  if (audio_url === undefined || audio_url === null) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Missing required field: audio_url'
    });
  }
  if (typeof audio_url !== 'string' || !audio_url.trim()) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'audio_url must be a non-empty string'
    });
  }
  if (metadata === undefined || metadata === null) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Missing required field: metadata'
    });
  }
  if (typeof metadata !== 'object' || Array.isArray(metadata)) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'metadata must be an object'
    });
  }

  const inputPath = path.join(UPLOAD_DIR, `in_${Date.now()}_${Math.random().toString(36).slice(2)}`);
  const ext = path.extname(new URL(audio_url).pathname) || '.mp3';
  const inputFile = inputPath + ext;
  const outputFile = path.join(OUTPUT_DIR, `out_${Date.now()}_${Math.random().toString(36).slice(2)}${ext}`);

  try {
    await fetchAudio(req, audio_url, inputFile);
  } catch (e) {
    return res.status(400).json({
      error: 'Bad Request',
      message: 'Failed to download audio from audio_url: ' + (e.message || String(e)),
      details: e.status === 403 ? 'Access denied (e.g. Supabase: check bucket is public or send Authorization)' : undefined
    });
  }

  const metaArgs = [
    '-i', inputFile,
    '-map_metadata', '-1',
    '-id3v2_version', '3',
  ];

  if (metadata.title) metaArgs.push('-metadata', `title=${metadata.title}`);
  if (metadata.artist) metaArgs.push('-metadata', `artist=${metadata.artist}`);
  if (metadata.album) metaArgs.push('-metadata', `album=${metadata.album}`);
  if (metadata.publisher) metaArgs.push('-metadata', `publisher=${metadata.publisher}`);
  if (metadata.comment) metaArgs.push('-metadata', `comment=${metadata.comment}`);
  if (metadata.copyright) metaArgs.push('-metadata', `copyright=${metadata.copyright}`);

  if (metadata.custom && typeof metadata.custom === 'object') {
    for (const [key, value] of Object.entries(metadata.custom)) {
      if (value != null && value !== '') metaArgs.push('-metadata', `${key}=${value}`);
    }
  }

  metaArgs.push('-c', 'copy', '-y', outputFile);

  return new Promise((resolve) => {
    execFile('ffmpeg', metaArgs, { timeout: 120000 }, (err, stdout, stderr) => {
      try { fs.unlinkSync(inputFile); } catch (_) {}
      if (err) {
        try { fs.unlinkSync(outputFile); } catch (_) {}
        return resolve(res.status(500).json({
          error: 'Processing failed',
          message: 'FFmpeg error: ' + (stderr || err.message || String(err))
        }));
      }
      const baseUrl = process.env.BASE_URL || 'https://aimuza.ru/api/ffmpeg';
      const outName = path.basename(outputFile);
      const output_url = `${baseUrl}/output/${outName}`;
      resolve(res.json({ output_url, cleaned_url: output_url, metadata }));
    });
  });
});

app.use('/output', express.static(OUTPUT_DIR));

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

app.listen(PORT, HOST, () => {
  console.log(`FFmpeg microservice listening on ${HOST}:${PORT}`);
});
