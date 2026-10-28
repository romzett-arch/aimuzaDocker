const fs = require('fs');
const { execFile } = require('child_process');
const fetch = require('node-fetch');

function execFileAsync(cmd, args, opts = {}) {
  if (/^(ffmpeg|ffprobe)(\.exe)?$/.test(require('path').basename(cmd))) {
    args=['-protocol_whitelist','file,pipe','-format_whitelist','mp3,wav,flac,ogg,mov,mp4,m4a,matroska,webm,aac',...args];
  }
  return new Promise((resolve, reject) => {
    execFile(cmd, args, opts, (err, stdout, stderr) => {
      if (err) reject(Object.assign(err, { stdout, stderr }));
      else resolve({ stdout, stderr });
    });
  });
}

const { downloadAudio: fetchAudio } = require('./safe-download');

function requireApiKey(API_KEY) {
  return (req, res, next) => {
    if (!API_KEY || API_KEY.length<32) return res.status(503).json({error:'Media service authentication is not configured'});
    const key = req.headers['x-api-key'];
    if (key !== API_KEY) {
      return res.status(401).json({ error: 'Invalid or missing API key' });
    }
    next();
  };
}

module.exports = { execFileAsync, fetchAudio, requireApiKey };
