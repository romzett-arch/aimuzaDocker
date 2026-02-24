const fs = require('fs');
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

function requireApiKey(API_KEY) {
  return (req, res, next) => {
    if (!API_KEY) return next();
    const key = req.headers['x-api-key'] || req.query.api_key;
    if (key !== API_KEY) {
      return res.status(401).json({ error: 'Invalid or missing API key' });
    }
    next();
  };
}

module.exports = { execFileAsync, fetchAudio, requireApiKey };
