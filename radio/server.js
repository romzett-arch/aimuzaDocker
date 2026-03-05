/**
 * AI Planet Radio Controller v3.0
 *
 * Manages: playlist generation, Liquidsoap control, metadata WebSocket,
 * boost injection, auction slots, predictions, ad scheduling, listener tracking.
 *
 * Runs alongside Icecast2 and Liquidsoap in the same container.
 */

const { Pool } = require('pg');
const http = require('http');
const { MetadataServer } = require('./lib/metadata-ws');
const liquidsoap = require('./lib/liquidsoap');
const { injectBoostedTracks } = require('./lib/boost-injector');
const { refreshPlaylist, resolvePredictions, manageAuctionSlots } = require('./queue');
const { handleTrackChanged, updateListenerCount, loadRadioConfig, getStats } = require('./stream');

const pool = new Pool({
  host: process.env.DB_HOST || 'db',
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME || 'aimuza',
  user: process.env.DB_USER || 'aimuza',
  password: process.env.DB_PASSWORD || 'password',
  max: 10,
  client_encoding: 'UTF8',
});

const PORT = parseInt(process.env.PORT || '3200');
const QUEUE_INTERVAL_MS = parseInt(process.env.QUEUE_INTERVAL_MS || '30000');
const PREDICTION_INTERVAL_MS = parseInt(process.env.PREDICTION_RESOLVE_INTERVAL_MS || '60000');
const BOOST_INTERVAL_MS = parseInt(process.env.BOOST_CHECK_INTERVAL_MS || '15000');

let radioConfig = null;

const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Radio-Skip-Secret, Authorization');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  try {
    if (req.url === '/health') {
      const lsUp = await liquidsoap.isUp().catch(() => false);
      res.writeHead(200);
      res.end(JSON.stringify({
        status: 'ok',
        service: 'aimuza-radio',
        version: '3.0.0',
        uptime: Math.round(process.uptime()),
        liquidsoap: lsUp,
        ws_clients: metadataWs.clients.size,
        listeners: metadataWs.listenersCount,
      }));
      return;
    }

    if (req.url === '/api/now-playing') {
      res.writeHead(200);
      res.end(JSON.stringify({
        track: metadataWs.currentTrack,
        listeners: metadataWs.listenersCount,
        queue_size: metadataWs.queue.length,
      }));
      return;
    }

    if (req.url === '/api/queue') {
      res.writeHead(200);
      res.end(JSON.stringify({ queue: metadataWs.queue.slice(0, 20) }));
      return;
    }

    if (req.url === '/api/listeners') {
      res.writeHead(200);
      res.end(JSON.stringify({ count: metadataWs.listenersCount }));
      return;
    }

    if (req.url === '/api/stats') {
      const stats = await getStats(pool, metadataWs);
      res.writeHead(200);
      res.end(JSON.stringify(stats));
      return;
    }

    if (req.method === 'POST' && req.url === '/api/internal/track-changed') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', async () => {
        try {
          const trackData = JSON.parse(body);
          await handleTrackChanged(pool, metadataWs, () => radioConfig, trackData);
          res.writeHead(200);
          res.end('{"ok":true}');
        } catch (e) {
          res.writeHead(400);
          res.end('{"error":"' + e.message + '"}');
        }
      });
      return;
    }

    if (req.method === 'POST' && req.url === '/api/skip') {
      const skipSecret = process.env.RADIO_SKIP_SECRET;
      if (skipSecret) {
        const authHeader = req.headers['x-radio-skip-secret'] || req.headers['authorization']?.replace('Bearer ', '');
        if (authHeader !== skipSecret) {
          res.writeHead(403);
          res.end('{"error":"forbidden"}');
          return;
        }
      }
      await liquidsoap.skip();
      res.writeHead(200);
      res.end('{"ok":true}');
      return;
    }

    res.writeHead(404);
    res.end('{"error":"not found"}');
  } catch (err) {
    res.writeHead(500);
    res.end('{"error":"' + err.message + '"}');
  }
});

const metadataWs = new MetadataServer(server, {
  jwtSecret: process.env.JWT_SECRET || process.env.SUPABASE_JWT_SECRET,
});

metadataWs.onReaction = async (ws, data) => {
  if (!ws.userId || !metadataWs.currentTrack) return;
  try {
    const result = await pool.query(
      'SELECT public.radio_award_listen_xp($1, $2, $3, $4, $5, $6, $7)',
      [ws.userId, metadataWs.currentTrack.track_id,
        Math.round(data.listen_duration || 30),
        Math.round(metadataWs.currentTrack.duration || 180),
        data.reaction || null, data.session_id || null, null]
    );
    if (result?.rows?.[0]) {
      const xpResult = result.rows[0].radio_award_listen_xp;
      if (xpResult) metadataWs.sendXpAwarded(ws.userId, xpResult);
    }
  } catch (err) {
    console.error('[Reaction] Error:', err.message);
  }
};

async function main() {
  console.log('═══════════════════════════════════════════');
  console.log(' AIMUZA Radio Controller v3.0');
  console.log(' DB: ' + (process.env.DB_HOST || 'db') + ':' + (process.env.DB_PORT || '5432') + '/' + (process.env.DB_NAME || 'aimuza'));
  console.log(' Playlist refresh: ' + QUEUE_INTERVAL_MS + 'ms');
  console.log('═══════════════════════════════════════════');

  try {
    await pool.query('SELECT 1');
    console.log('[DB] Connected');
  } catch (error) {
    console.error('[DB] Failed:', error.message);
    process.exit(1);
  }

  await loadRadioConfig(pool, (config) => { radioConfig = config; });

  server.listen(PORT, () => {
    console.log('[HTTP] Listening on :' + PORT);
    console.log('[WS] Ready on :' + PORT + '/ws');
  });

  await refreshPlaylist(pool, metadataWs);
  await new Promise(r => setTimeout(r, 500));

  let lsReady = false;
  for (let i = 0; i < 30; i++) {
    lsReady = await liquidsoap.isUp();
    if (lsReady) break;
    console.log('[Liquidsoap] Waiting...');
    await new Promise(r => setTimeout(r, 2000));
  }
  console.log('[Liquidsoap] ' + (lsReady ? 'Ready' : 'Not available (will retry)'));

  setInterval(() => refreshPlaylist(pool, metadataWs), QUEUE_INTERVAL_MS);
  setInterval(() => resolvePredictions(pool, metadataWs), PREDICTION_INTERVAL_MS);
  setInterval(() => manageAuctionSlots(pool, metadataWs), 30000);
  setInterval(() => injectBoostedTracks(pool), BOOST_INTERVAL_MS);
  setInterval(() => updateListenerCount(metadataWs), 10000);
  setInterval(() => loadRadioConfig(pool, (config) => { radioConfig = config; }), 300000);

  // Cron: автопродление подписок (каждый час)
  const renewSubscriptions = async () => {
    try {
      const result = await pool.query('SELECT public.renew_expired_subscriptions()');
      const data = result?.rows?.[0]?.renew_expired_subscriptions;
      if (data && (data.renewed > 0 || data.past_due > 0 || data.expired > 0)) {
        console.log('[Subscriptions] Renewed:', data.renewed, 'Past due:', data.past_due, 'Expired:', data.expired);
      }
    } catch (err) {
      console.error('[Subscriptions] Renewal error:', err.message);
    }
  };
  await renewSubscriptions();
  setInterval(renewSubscriptions, 3600000);

  console.log('[Radio] All workers started');

  const shutdown = async () => {
    console.log('[Radio] Shutting down...');
    server.close();
    await pool.end();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

main().catch((err) => {
  console.error('[Fatal]', err);
  process.exit(1);
});
