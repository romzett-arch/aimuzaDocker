const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { execFileAsync, fetchAudio } = require('./utils');

function pickMp3Bitrate(inputBitrate) {
  const allowed = [96, 128, 160, 192, 224, 256, 320];
  if (!inputBitrate || Number.isNaN(inputBitrate)) return 192;
  const inputKbps = inputBitrate / 1000;
  return allowed.find((rate) => rate >= inputKbps) || 320;
}

function parseLoudnormJson(stderr) {
  const raw = (stderr || '').replace(/\r/g, '');
  const start = raw.indexOf('{');
  if (start === -1 || !raw.includes('input_i')) return null;

  let depth = 0;
  let end = start;
  for (let i = start; i < raw.length; i++) {
    if (raw[i] === '{') depth++;
    else if (raw[i] === '}') {
      depth--;
      if (depth === 0) {
        end = i + 1;
        break;
      }
    }
  }

  return JSON.parse(raw.slice(start, end));
}

function safeNumber(value, fallback = null) {
  const parsed = typeof value === 'number' ? value : parseFloat(String(value));
  return Number.isFinite(parsed) ? parsed : fallback;
}

function getPublicFfmpegBaseUrl() {
  const rawBaseUrl = process.env.BASE_URL || 'https://aimuza.ru';
  return rawBaseUrl.endsWith('/api/ffmpeg') ? rawBaseUrl : `${rawBaseUrl}/api/ffmpeg`;
}

function normalizeDownloadCacheKey(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toLowerCase();
  return /^[a-f0-9]{64}$/.test(normalized) ? normalized : null;
}

function appendMetadataArgs(args, metadata) {
  for (const [key, value] of Object.entries(metadata)) {
    if (key === 'custom') continue;
    if (value != null && value !== '' && typeof value !== 'object') {
      args.push('-metadata', `${String(key)}=${String(value)}`);
    }
  }

  const custom = metadata.custom;
  if (custom && typeof custom === 'object' && !Array.isArray(custom)) {
    for (const [key, value] of Object.entries(custom)) {
      if (value != null && value !== '' && typeof value !== 'object') {
        args.push('-metadata', `${String(key)}=${String(value)}`);
      }
    }
  }
}

function createAnalyzeHandler(UPLOAD_DIR) {
  return async (req, res) => {
    const body = req.body;
    if (!body || typeof body !== 'object') {
      return res.status(400).json({ error: 'Bad Request', message: 'Body must be JSON with audio_url' });
    }

    const audio_url = body.audio_url;
    if (typeof audio_url !== 'string' || !audio_url.trim()) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is required (string)' });
    }

    let parsedUrl;
    try { parsedUrl = new URL(audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }

    const ext = path.extname(parsedUrl.pathname) || '.bin';
    const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const inputFile = path.join(UPLOAD_DIR, `analyze_in_${suffix}${ext}`);

    try {
      await fetchAudio(req, audio_url, inputFile);

      const { stdout } = await execFileAsync('ffprobe', [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        inputFile,
      ], { timeout: 30000 });

      const probe = JSON.parse(stdout || '{}');
      const { stderr } = await execFileAsync('ffmpeg', [
        '-i', inputFile,
        '-af', 'loudnorm=I=-10:TP=-1:LRA=11:print_format=json',
        '-f', 'null', '-'
      ], { timeout: 120000 });

      const loudnorm = parseLoudnormJson(stderr);
      const audioStream = probe?.streams?.find((stream) => stream.codec_type === 'audio') || {};
      const sampleRate = safeNumber(audioStream.sample_rate, 44100);

      return res.json({
        format: probe?.format || {},
        streams: probe?.streams || [],
        lufs: loudnorm ? {
          integrated: safeNumber(loudnorm.input_i, -14),
          true_peak: safeNumber(loudnorm.input_tp, -1),
          range: safeNumber(loudnorm.input_lra, 0),
          threshold: safeNumber(loudnorm.input_thresh, 0),
          target_offset: safeNumber(loudnorm.target_offset, 0),
        } : null,
        spectrum: {
          // Conservative fallback: exact spectral cutoff analysis is not implemented yet.
          high_freq_cutoff: Math.round(sampleRate / 2),
        },
      });
    } catch (e) {
      return res.status(500).json({
        error: 'Analyze failed',
        message: e.message || String(e),
      });
    } finally {
      try { fs.unlinkSync(inputFile); } catch (_) {}
    }
  };
}

function createNormalizeHandler(UPLOAD_DIR, OUTPUT_DIR) {
  return async (req, res) => {
    const body = req.body;
    if (!body || typeof body !== 'object') {
      return res.status(400).json({ error: 'Bad Request', message: 'Body must be JSON with audio_url' });
    }
    const audio_url = body.audio_url;
    if (typeof audio_url !== 'string' || !audio_url.trim()) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is required (string)' });
    }
    let target_lufs = body.target_lufs;
    if (typeof target_lufs === 'number' && !isNaN(target_lufs)) { }
    else if (typeof target_lufs === 'string') { target_lufs = parseFloat(target_lufs); }
    else { target_lufs = -10; }
    if (typeof target_lufs !== 'number' || isNaN(target_lufs)) target_lufs = -10;
    let target_true_peak = body.target_true_peak;
    if (typeof target_true_peak === 'string') target_true_peak = parseFloat(target_true_peak);
    if (typeof target_true_peak !== 'number' || isNaN(target_true_peak) || target_true_peak > -0.1 || target_true_peak < -9) {
      target_true_peak = -1;
    }
    const strip_metadata = body.strip_metadata !== false;
    const brand_metadata = body.brand_metadata !== false;
    const metadata = body.metadata && typeof body.metadata === 'object' && !Array.isArray(body.metadata) ? body.metadata : {};
    const downloadCacheKey = normalizeDownloadCacheKey(body.cache_key);

    let parsedUrl;
    try { parsedUrl = new URL(audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }
    const ext = path.extname(parsedUrl.pathname) || '.mp3';
    const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const inputFile = path.join(UPLOAD_DIR, `norm_in_${suffix}${ext}`);
    const outName = downloadCacheKey
      ? `download_${downloadCacheKey}.mp3`
      : `normalized_${suffix}.mp3`;
    const outputFile = path.join(OUTPUT_DIR, outName);
    const encodingOutputFile = downloadCacheKey
      ? path.join(OUTPUT_DIR, `.download_${downloadCacheKey}_${suffix}.tmp.mp3`)
      : outputFile;

    if (downloadCacheKey) {
      try {
        const cached = fs.statSync(outputFile);
        if (cached.isFile() && cached.size >= 1000) {
          const now = new Date();
          fs.utimesSync(outputFile, now, now);
          const baseUrl = getPublicFfmpegBaseUrl();
          const output_url = `${baseUrl}/output/${outName}`;
          return res.json({ output_url, normalized_url: output_url, cache_hit: true });
        }
      } catch (_) {
        // Cache miss: generate the deterministic download variant below.
      }
    }

    try {
      await fetchAudio(req, audio_url, inputFile);
    } catch (e) {
      return res.status(400).json({
        error: 'Bad Request',
        message: 'Failed to download audio: ' + (e.message || String(e)),
        details: e.status === 403 ? 'Access denied (e.g. Supabase: check bucket is public or send Authorization)' : undefined
      });
    }

    let sourceProbe = null;
    try {
      const { stdout } = await execFileAsync('ffprobe', [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        inputFile,
      ], { timeout: 30000 });
      sourceProbe = JSON.parse(stdout || '{}');
    } catch (e) {
      console.warn('[normalize] ffprobe failed, using safe MP3 defaults:', e.message || String(e));
    }

    let analysis = null;
    try {
      const { stderr } = await execFileAsync('ffmpeg', [
        '-i', inputFile,
        '-af', `loudnorm=I=${target_lufs}:TP=${target_true_peak}:LRA=11:print_format=json`,
        '-f', 'null', '-'
      ], { timeout: 120000 });
      analysis = parseLoudnormJson(stderr);
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

    // Dynamic mode performs the compression/limiting needed to reach a loud
    // target without clipping. Supplying linear measured values here can make
    // FFmpeg fall back inconsistently and undershoot the requested loudness.
    const filter = `loudnorm=I=${target_lufs}:TP=${target_true_peak}:LRA=11:linear=false`;
    const args = ['-i', inputFile, '-af', filter];
    const audioStream = sourceProbe?.streams?.find((stream) => stream.codec_type === 'audio') || {};
    const inputBitrate = parseInt(audioStream.bit_rate || sourceProbe?.format?.bit_rate || '0', 10);
    const targetBitrateKbps = pickMp3Bitrate(inputBitrate);
    if (strip_metadata) args.push('-map_metadata', '-1');
    args.push('-id3v2_version', '3');
    if (brand_metadata && Object.keys(metadata).length) {
      appendMetadataArgs(args, metadata);
    }
    args.push(
      '-c:a', 'libmp3lame',
      '-b:a', `${targetBitrateKbps}k`,
      '-ar', String(audioStream.sample_rate || 44100),
      '-ac', String(audioStream.channels || 2),
      '-y', encodingOutputFile
    );

    return new Promise((resolve) => {
      execFile('ffmpeg', args, { timeout: 180000 }, (err, stdout, stderr) => {
        try { fs.unlinkSync(inputFile); } catch (_) {}
        if (err) {
          try { fs.unlinkSync(encodingOutputFile); } catch (_) {}
          return resolve(res.status(500).json({
            error: 'Normalization failed',
            message: 'FFmpeg: ' + (stderr || err.message || String(err))
          }));
        }
        if (downloadCacheKey) {
          try {
            fs.renameSync(encodingOutputFile, outputFile);
          } catch (renameError) {
            try { fs.unlinkSync(encodingOutputFile); } catch (_) {}
            return resolve(res.status(500).json({
              error: 'Cache publish failed',
              message: renameError.message || String(renameError)
            }));
          }
        }
        const baseUrl = getPublicFfmpegBaseUrl();
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
          input_bitrate: Number.isNaN(inputBitrate) ? undefined : inputBitrate,
          output_bitrate: targetBitrateKbps * 1000,
          peak_before: isNaN(peak_before) ? undefined : peak_before,
          peak_after: isNaN(peak_after) ? undefined : peak_after,
          cache_hit: false
        }));
      });
    });
  };
}

function createProcessWavHandler(UPLOAD_DIR, OUTPUT_DIR) {
  return async (req, res) => {
    const body = req.body;
    if (!body || typeof body !== 'object') {
      return res.status(400).json({ error: 'Bad Request', message: 'Body must be JSON with audio_url' });
    }
    const audio_url = body.audio_url;
    if (typeof audio_url !== 'string' || !audio_url.trim()) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is required (string)' });
    }

    let target_lufs = body.target_lufs;
    if (typeof target_lufs === 'number' && !isNaN(target_lufs)) { }
    else if (typeof target_lufs === 'string') { target_lufs = parseFloat(target_lufs); }
    else { target_lufs = -10; }
    if (typeof target_lufs !== 'number' || isNaN(target_lufs)) target_lufs = -10;

    const metadata = body.metadata && typeof body.metadata === 'object' && !Array.isArray(body.metadata) ? body.metadata : {};

    let parsedUrl;
    try { parsedUrl = new URL(audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }
    const ext = path.extname(parsedUrl.pathname) || '.wav';
    const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const inputFile = path.join(UPLOAD_DIR, `wav_in_${suffix}${ext}`);
    const outName = `processed_${suffix}.wav`;
    const outputFile = path.join(OUTPUT_DIR, outName);

    try {
      await fetchAudio(req, audio_url, inputFile);
    } catch (e) {
      return res.status(400).json({
        error: 'Bad Request',
        message: 'Failed to download audio: ' + (e.message || String(e)),
        details: e.status === 403 ? 'Access denied' : undefined
      });
    }

    let analysis = null;
    try {
      const { stderr } = await execFileAsync('ffmpeg', [
        '-i', inputFile,
        '-af', `loudnorm=I=${target_lufs}:TP=-1:LRA=11:print_format=json`,
        '-f', 'null', '-'
      ], { timeout: 180000 });
      analysis = parseLoudnormJson(stderr);
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
    const args = ['-i', inputFile, '-af', filter, '-map_metadata', '-1'];

    if (Object.keys(metadata).length) {
      for (const [k, v] of Object.entries(metadata)) {
        if (v != null && v !== '') args.push('-metadata', `${String(k)}=${String(v)}`);
      }
    }

    args.push('-c:a', 'pcm_s16le', '-ar', '44100', '-ac', '2', '-y', outputFile);

    return new Promise((resolve) => {
      execFile('ffmpeg', args, { timeout: 90000 }, (err, stdout, stderr) => {
        try { fs.unlinkSync(inputFile); } catch (_) {}
        if (err) {
          try { fs.unlinkSync(outputFile); } catch (_) {}
          return resolve(res.status(500).json({
            error: 'WAV processing failed',
            message: 'FFmpeg: ' + (stderr || err.message || String(err))
          }));
        }
        const baseUrl = getPublicFfmpegBaseUrl();
        const output_url = `${baseUrl}/output/${outName}`;
        const original_lufs = parseFloat(analysis.input_i);
        const normalized_lufs = target_lufs;
        const peak_before = parseFloat(analysis.input_tp);
        const peak_after = parseFloat(analysis.output_tp);
        return resolve(res.json({
          output_url,
          original_lufs,
          normalized_lufs,
          peak_before: isNaN(peak_before) ? undefined : peak_before,
          peak_after: isNaN(peak_after) ? undefined : peak_after,
          format: { codec: 'pcm_s16le', sample_rate: 44100, channels: 2, bit_depth: 16 }
        }));
      });
    });
  };
}

function createCleanMetadataHandler(UPLOAD_DIR, OUTPUT_DIR) {
  return async (req, res) => {
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

    const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const downloadCacheKey = normalizeDownloadCacheKey(body.cache_key);
    const inputPath = path.join(UPLOAD_DIR, `in_${suffix}`);
    let parsedCleanUrl;
    try { parsedCleanUrl = new URL(audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }
    const ext = path.extname(parsedCleanUrl.pathname) || '.mp3';
    const inputFile = inputPath + ext;
    const outName = downloadCacheKey ? `download_${downloadCacheKey}${ext}` : `out_${suffix}${ext}`;
    const outputFile = path.join(OUTPUT_DIR, outName);
    const writingFile = downloadCacheKey
      ? path.join(OUTPUT_DIR, `.download_${downloadCacheKey}_${suffix}.tmp${ext}`)
      : outputFile;

    if (downloadCacheKey) {
      try {
        if (fs.statSync(outputFile).size > 1000) {
          const now = new Date();
          fs.utimesSync(outputFile, now, now);
          const output_url = `${getPublicFfmpegBaseUrl()}/output/${outName}`;
          return res.json({ output_url, cleaned_url: output_url, metadata, cache_hit: true });
        }
      } catch (_) {
        // Cache miss.
      }
    }

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
    appendMetadataArgs(metaArgs, metadata);
    metaArgs.push('-c', 'copy', '-y', writingFile);

    return new Promise((resolve) => {
      execFile('ffmpeg', metaArgs, { timeout: 120000 }, (err, stdout, stderr) => {
        try { fs.unlinkSync(inputFile); } catch (_) {}
        if (err) {
          try { fs.unlinkSync(writingFile); } catch (_) {}
          return resolve(res.status(500).json({
            error: 'Processing failed',
            message: 'FFmpeg error: ' + (stderr || err.message || String(err))
          }));
        }
        if (writingFile !== outputFile) {
          try {
            fs.renameSync(writingFile, outputFile);
          } catch (renameError) {
            if (!fs.existsSync(outputFile)) {
              return resolve(res.status(500).json({ error: 'Cache publish failed', message: renameError.message || String(renameError) }));
            }
            try { fs.unlinkSync(writingFile); } catch (_) {}
          }
        }
        const baseUrl = getPublicFfmpegBaseUrl();
        const output_url = `${baseUrl}/output/${outName}`;
        resolve(res.json({ output_url, cleaned_url: output_url, metadata, cache_hit: false }));
      });
    });
  };
}

function createConvertFormatHandler(UPLOAD_DIR, OUTPUT_DIR) {
  return async (req, res) => {
    const body = req.body;
    if (!body || typeof body !== 'object' || typeof body.audio_url !== 'string' || !body.audio_url.trim()) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is required' });
    }
    const format = body.format === 'flac' ? 'flac' : body.format === 'wav' ? 'wav' : null;
    if (!format) return res.status(400).json({ error: 'Bad Request', message: 'format must be wav or flac' });
    const cacheKey = normalizeDownloadCacheKey(body.cache_key);
    if (!cacheKey) return res.status(400).json({ error: 'Bad Request', message: 'cache_key must be SHA-256' });
    let parsedUrl;
    try { parsedUrl = new URL(body.audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }
    const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const inputFile = path.join(UPLOAD_DIR, `format_in_${suffix}${path.extname(parsedUrl.pathname) || '.mp3'}`);
    const outName = `distribution_${cacheKey}.${format}`;
    const outputFile = path.join(OUTPUT_DIR, outName);
    const writingFile = path.join(OUTPUT_DIR, `.distribution_${cacheKey}_${suffix}.tmp.${format}`);
    try {
      if (fs.statSync(outputFile).size > 1000) {
        const now = new Date();
        fs.utimesSync(outputFile, now, now);
        return res.json({ output_url: `${getPublicFfmpegBaseUrl()}/output/${outName}`, format, cache_hit: true });
      }
    } catch (_) {}
    try {
      await fetchAudio(req, body.audio_url, inputFile);
    } catch (error) {
      return res.status(400).json({ error: 'Bad Request', message: 'Failed to download audio: ' + (error.message || String(error)) });
    }
    const args = ['-i', inputFile, '-map_metadata', '-1'];
    appendMetadataArgs(args, body.metadata && typeof body.metadata === 'object' ? body.metadata : {});
    if (format === 'wav') args.push('-c:a', 'pcm_s24le', '-ar', '44100', '-ac', '2');
    else args.push('-c:a', 'flac', '-sample_fmt', 's32', '-ar', '44100', '-ac', '2');
    args.push('-y', writingFile);
    return new Promise((resolve) => {
      execFile('ffmpeg', args, { timeout: 180000 }, (err, stdout, stderr) => {
        try { fs.unlinkSync(inputFile); } catch (_) {}
        if (err) {
          try { fs.unlinkSync(writingFile); } catch (_) {}
          return resolve(res.status(500).json({ error: 'Format conversion failed', message: stderr || err.message || String(err) }));
        }
        try { fs.renameSync(writingFile, outputFile); } catch (renameError) {
          if (!fs.existsSync(outputFile)) return resolve(res.status(500).json({ error: 'Cache publish failed', message: renameError.message || String(renameError) }));
          try { fs.unlinkSync(writingFile); } catch (_) {}
        }
        return resolve(res.json({ output_url: `${getPublicFfmpegBaseUrl()}/output/${outName}`, format, cache_hit: false }));
      });
    });
  };
}

module.exports = { createAnalyzeHandler, createNormalizeHandler, createProcessWavHandler, createCleanMetadataHandler, createConvertFormatHandler };
