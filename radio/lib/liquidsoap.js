/**
 * Liquidsoap Telnet Client
 * Controls Liquidsoap via Telnet API (port 1234)
 */

const net = require('net');

const TELNET_HOST = '127.0.0.1';
const TELNET_PORT = 1234;
const TIMEOUT_MS = 5000;

function sendCommand(command) {
  return new Promise((resolve, reject) => {
    const client = new net.Socket();
    let data = '';
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        client.destroy();
        reject(new Error(`Telnet timeout: ${command}`));
      }
    }, TIMEOUT_MS);

    client.connect(TELNET_PORT, TELNET_HOST, () => {
      client.write(command + '\n');
      client.write('quit\n');
    });

    client.on('data', (chunk) => {
      data += chunk.toString();
    });

    client.on('end', () => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        const lines = data.split('\n').filter(l => l.trim() && l.trim() !== 'Bye!');
        resolve(lines.join('\n').trim());
      }
    });

    client.on('error', (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(err);
      }
    });
  });
}

async function pushTrack(audioUrl, metadata = {}) {
  const escape = (s) => String(s || '').replace(/"/g, "'");
  const parts = [];
  if (metadata.title != null) parts.push(`title="${escape(metadata.title)}"`);
  if (metadata.artist != null) parts.push(`artist="${escape(metadata.artist)}"`);
  if (metadata.track_id != null) parts.push(`track_id="${metadata.track_id}"`);
  if (metadata.cover_url != null) parts.push(`cover_url="${escape(metadata.cover_url)}"`);
  if (metadata.duration != null) parts.push(`duration="${metadata.duration}"`);

  const annotate = parts.length > 0
    ? `annotate:${parts.join(',')}:${audioUrl}`
    : audioUrl;

  return sendCommand(`priority.push ${annotate}`);
}

async function skip() {
  return sendCommand('main.skip');
}

async function reloadPlaylist() {
  return sendCommand('main.reload');
}

async function getRemaining() {
  try {
    const result = await sendCommand('main.remaining');
    return parseFloat(result) || 0;
  } catch {
    return 0;
  }
}

async function isUp() {
  try {
    await sendCommand('version');
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  sendCommand,
  pushTrack,
  skip,
  reloadPlaylist,
  getRemaining,
  isUp,
};
