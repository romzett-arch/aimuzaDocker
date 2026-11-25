const { spawn } = require('node:child_process');
const { mkdtemp, rm, writeFile } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

function transcode(args, input, maxBytes, timeout) {
  return new Promise((resolve, reject) => {
    const ffmpeg = spawn('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-nostdin', ...args,
    ], { stdio: ['pipe', 'pipe', 'ignore'], timeout });
    const chunks = [];
    let length = 0;
    ffmpeg.stdin.on('error', () => {});
    ffmpeg.stdout.on('data', chunk => {
      length += chunk.length;
      if (length > maxBytes) ffmpeg.kill();
      else chunks.push(chunk);
    });
    ffmpeg.on('error', reject);
    ffmpeg.on('close', code => {
      if (code !== 0 || !length || length > maxBytes) reject(new Error('Invalid recording'));
      else resolve(Buffer.concat(chunks, length));
    });
    ffmpeg.stdin.end(input);
  });
}

function wavDuration(wav) {
  if (wav.toString('ascii', 0, 4) !== 'RIFF' || wav.toString('ascii', 8, 12) !== 'WAVE') return 0;
  let offset = 12;
  while (offset + 8 <= wav.length) {
    const size = wav.readUInt32LE(offset + 4);
    if (wav.toString('ascii', offset, offset + 4) === 'data') return (wav.length - offset - 8) / 48000;
    offset += 8 + size + size % 2;
  }
  return 0;
}

async function voiceRecording(req, res) {
  const limit = Number(req.query.limit);
  if (![60, 240].includes(limit) || !Buffer.isBuffer(req.body) || !req.body.length) {
    return res.status(400).json({ error: 'Invalid audio' });
  }
  let directory;
  try {
    directory = await mkdtemp(join(tmpdir(), 'voice-'));
    const sourceFile = join(directory, 'input');
    await writeFile(sourceFile, req.body, { mode: 0o600 });
    const wav = await transcode([
      '-protocol_whitelist', 'file,pipe', '-format_whitelist', 'mov,mp3,wav,matroska,webm,ogg,flac,aac',
      '-i', sourceFile, '-map', '0:a:0', '-map_metadata', '-1', '-vn',
      '-t', String(limit + 1), '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', '-f', 'wav', 'pipe:1',
    ], undefined, limit * 48000 + 8192, 23000);
    const duration = wavDuration(wav);
    if (!duration || duration > limit) return res.status(400).json({ error: 'Invalid recording duration' });
    const source = limit === 240;
    const start = source ? Number(req.query.start) : 0;
    const end = source ? Math.min(Number(req.query.end), duration) : duration;
    const clipDuration = Math.floor((end - start + 1e-8) * 100) / 100;
    if (!(start >= 0 && clipDuration > 0) || (source && (clipDuration < 9.98 || clipDuration > 120))) {
      return res.status(400).json({ error: 'Invalid recording selection' });
    }
    const audio = await transcode([
      '-protocol_whitelist', 'pipe', '-f', 'wav', '-i', 'pipe:0',
      '-ss', String(start), '-t', String(clipDuration),
      '-c:a', 'libmp3lame', '-b:a', '96k', '-f', 'mp3', 'pipe:1',
    ], wav, 4 * 1024 * 1024, 9000);
    res.set({ 'X-Audio-Duration': String(clipDuration), 'Cache-Control': 'no-store' });
    return res.type('audio/mpeg').send(audio);
  } catch {
    return res.status(400).json({ error: 'Invalid audio or recording duration' });
  } finally {
    if (directory) await rm(directory, { recursive: true, force: true }).catch(() => {});
  }
}

module.exports = { voiceRecording };
