const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { execFileAsync, fetchAudio } = require('./utils');

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
    else { target_lufs = -14; }
    if (typeof target_lufs !== 'number' || isNaN(target_lufs)) target_lufs = -14;
    const strip_metadata = body.strip_metadata !== false;
    const brand_metadata = body.brand_metadata !== false;
    const metadata = body.metadata && typeof body.metadata === 'object' && !Array.isArray(body.metadata) ? body.metadata : {};

    let parsedUrl;
    try { parsedUrl = new URL(audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }
    const ext = path.extname(parsedUrl.pathname) || '.mp3';
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
    else { target_lufs = -14; }
    if (typeof target_lufs !== 'number' || isNaN(target_lufs)) target_lufs = -14;

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
        const baseUrl = process.env.BASE_URL || 'https://aimuza.ru/api/ffmpeg';
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

    const inputPath = path.join(UPLOAD_DIR, `in_${Date.now()}_${Math.random().toString(36).slice(2)}`);
    let parsedCleanUrl;
    try { parsedCleanUrl = new URL(audio_url); } catch (_) {
      return res.status(400).json({ error: 'Bad Request', message: 'audio_url is not a valid URL' });
    }
    const ext = path.extname(parsedCleanUrl.pathname) || '.mp3';
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
        resolve(res.json({ output_url, metadata }));
      });
    });
  };
}

module.exports = { createNormalizeHandler, createProcessWavHandler, createCleanMetadataHandler };
