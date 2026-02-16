/**
 * AI Planet Sound — Realtime WebSocket Server
 * 
 * Совместим с Supabase Realtime (Phoenix channels protocol).
 * Слушает PostgreSQL LISTEN/NOTIFY и рассылает события подписчикам.
 * Поддерживает postgres_changes и presence.
 */

import { WebSocketServer } from 'ws';
import pg from 'pg';
import { URL } from 'url';

// A8: JWT validation (optional — works without jsonwebtoken package)
let jwt = null;
try {
  jwt = (await import('jsonwebtoken')).default;
} catch {
  console.warn('[Realtime] jsonwebtoken not installed — JWT validation disabled');
}

const WS_PORT = parseInt(process.env.WS_PORT || '4000');
const JWT_SECRET = process.env.JWT_SECRET || '';
const DB_CONFIG = {
  host: process.env.DB_HOST || 'db',
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME || 'aimuza',
  user: process.env.DB_USER || 'aimuza',
  password: process.env.DB_PASSWORD || 'aimuza_secret',
};

// ─── Presence state (in-memory) ────────────────────────────────────
// Map<channelTopic, Map<presenceKey, { metas: [...] }>>
const presenceState = new Map();

// ─── Client subscriptions ──────────────────────────────────────────
// Each WebSocket client has a Set of subscribed topics
// and for each topic, the filter config
const clientSubs = new WeakMap(); // ws -> Map<topic, { pgConfigs, presenceKey }>

// ─── PostgreSQL LISTEN ─────────────────────────────────────────────
let pgClient = null;
let reconnectTimer = null;

async function connectPg() {
  try {
    pgClient = new pg.Client(DB_CONFIG);
    await pgClient.connect();
    await pgClient.query('LISTEN table_changes');
    console.log('[Realtime] PG LISTEN connected');

    pgClient.on('notification', (msg) => {
      if (msg.channel === 'table_changes' && msg.payload) {
        try {
          const data = JSON.parse(msg.payload);
          console.log(`[Realtime] NOTIFY ${data.type} on ${data.schema}.${data.table} → ${wss.clients.size} client(s)`);
          broadcastChange(data);
        } catch (e) {
          console.error('[Realtime] Bad NOTIFY payload:', e.message);
        }
      }
    });

    pgClient.on('error', (err) => {
      console.error('[Realtime] PG error:', err.message);
      scheduleReconnect();
    });

    pgClient.on('end', () => {
      console.warn('[Realtime] PG connection ended');
      scheduleReconnect();
    });
  } catch (err) {
    console.error('[Realtime] PG connect failed:', err.message);
    scheduleReconnect();
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(async () => {
    reconnectTimer = null;
    pgClient = null;
    await connectPg();
  }, 3000);
}

// ─── Broadcast postgres_changes to subscribers ─────────────────────
function broadcastChange(data) {
  const { table, schema, type, record, old_record } = data;
  const eventType = type === 'INSERT' ? 'INSERT' : type === 'UPDATE' ? 'UPDATE' : 'DELETE';

  wss.clients.forEach((ws) => {
    if (ws.readyState !== 1) return; // OPEN
    const subs = clientSubs.get(ws);
    if (!subs) return;

    subs.forEach((config, topic) => {
      if (!config.pgConfigs) return;

      for (const pgConf of config.pgConfigs) {
        // Match table
        if (pgConf.table && pgConf.table !== table) continue;
        // Match schema
        if (pgConf.schema && pgConf.schema !== schema) continue;
        // Match event (* = all)
        if (pgConf.event !== '*' && pgConf.event !== eventType) continue;
        // Match filter (e.g., "user_id=eq.abc-123")
        if (pgConf.filter && record) {
          if (!matchFilter(pgConf.filter, record)) continue;
        }

        // Send postgres_changes event
        const msg = {
          topic,
          event: 'postgres_changes',
          payload: {
            data: {
              table,
              schema,
              type: eventType,
              record: record || null,
              old_record: old_record || null,
              commit_timestamp: new Date().toISOString(),
            },
            ids: [0], // Supabase client expects this
          },
          ref: null,
        };
        ws.send(JSON.stringify(msg));
        break; // one match per pgConf set is enough
      }
    });
  });
}

/**
 * Match PostgREST-style filter: "column=eq.value"
 */
function matchFilter(filter, record) {
  const match = filter.match(/^(\w+)=eq\.(.+)$/);
  if (!match) return true; // unknown filter format — pass through
  const [, col, val] = match;
  return String(record[col]) === val;
}

// ─── WebSocket Server ──────────────────────────────────────────────
const wss = new WebSocketServer({ port: WS_PORT, path: '/websocket' });

// Also accept connections without /websocket path (for flexibility)
const wss2 = new WebSocketServer({ noServer: true });

wss.on('connection', handleConnection);

wss.on('listening', () => {
  console.log(`[Realtime] WebSocket listening on :${WS_PORT}/websocket`);
});

function handleConnection(ws, req) {
  const clientIp = req.headers['x-real-ip'] || req.socket.remoteAddress || 'unknown';
  console.log(`[Realtime] Client connected from ${clientIp} — total: ${wss.clients.size}`);

  const subs = new Map();
  clientSubs.set(ws, subs);

  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw);
      console.log(`[Realtime] MSG from ${clientIp}: event=${msg.event} topic=${msg.topic} ref=${msg.ref}`);
      handleMessage(ws, msg, subs);
    } catch (e) {
      console.warn(`[Realtime] Bad message from ${clientIp}:`, String(raw).slice(0, 200));
    }
  });

  ws.on('close', (code, reason) => {
    console.log(`[Realtime] Client disconnected — code=${code} reason=${String(reason).slice(0, 100)}`);
    console.log(`[Realtime] Client disconnected — remaining: ${wss.clients.size - 1}`);
    // Clean up presence
    subs.forEach((config, topic) => {
      if (config.presenceKey) {
        removePresence(topic, config.presenceKey, ws);
      }
    });
    clientSubs.delete(ws);
  });
}

function handleMessage(ws, msg, subs) {
  const { topic, event, payload, ref } = msg;

  switch (event) {
    case 'phx_join':
      handleJoin(ws, topic, payload, ref, subs);
      break;

    case 'phx_leave':
      handleLeave(ws, topic, ref, subs);
      break;

    case 'heartbeat':
      send(ws, { topic: 'phoenix', event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
      break;

    case 'access_token':
      // A8: Validate JWT token from client (if jsonwebtoken is available)
      try {
        const token = payload?.access_token || payload;
        if (jwt && JWT_SECRET && typeof token === 'string') {
          const decoded = jwt.verify(token, JWT_SECRET);
          ws.userId = decoded.sub || null;
          ws.userRole = decoded.role || 'authenticated';
        }
        send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
      } catch (jwtErr) {
        console.warn('[Realtime] Invalid JWT token:', jwtErr.message);
        send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
      }
      break;

    case 'presence':
      handlePresenceEvent(ws, topic, payload, ref, subs);
      break;

    case 'presence_track':
      handlePresenceTrack(ws, topic, payload, ref, subs);
      break;

    case 'presence_untrack':
      handlePresenceUntrack(ws, topic, ref, subs);
      break;

    default:
      // Unknown event — reply ok
      if (ref) {
        send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
      }
  }
}

// ─── Phoenix Join ──────────────────────────────────────────────────
function handleJoin(ws, topic, payload, ref, subs) {
  const config = {};

  // Parse postgres_changes config from payload
  if (payload?.config?.postgres_changes) {
    config.pgConfigs = payload.config.postgres_changes;
  }

  // Parse presence config
  if (payload?.config?.presence) {
    config.presenceKey = payload.config.presence.key || null;
  }

  subs.set(topic, config);

  // Reply with ok + current presence state if applicable
  const response = {};
  if (config.presenceKey || topic.includes('presence') || topic.includes('typing') || topic.includes('online')) {
    response.presence_state = getPresenceState(topic);
  }

  // For postgres_changes topics, include subscription IDs
  if (config.pgConfigs) {
    response.postgres_changes = config.pgConfigs.map((pc, i) => ({ id: i, ...pc }));
  }

  send(ws, {
    topic,
    event: 'phx_reply',
    payload: { status: 'ok', response },
    ref,
  });

  // Send system message that Supabase client expects
  send(ws, {
    topic,
    event: 'system',
    payload: { status: 'ok', channel: topic, extension: 'postgres_changes' },
    ref: null,
  });
}

// ─── Phoenix Leave ─────────────────────────────────────────────────
function handleLeave(ws, topic, ref, subs) {
  const config = subs.get(topic);
  if (config?.presenceKey) {
    removePresence(topic, config.presenceKey, ws);
  }
  subs.delete(topic);

  if (ref) {
    send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
  }
}

// ─── Presence ──────────────────────────────────────────────────────
function getPresenceState(topic) {
  const state = presenceState.get(topic);
  if (!state) return {};
  const result = {};
  state.forEach((data, key) => {
    result[key] = { metas: data.metas };
  });
  return result;
}

function handlePresenceTrack(ws, topic, payload, ref, subs) {
  const config = subs.get(topic) || {};
  const key = config.presenceKey || payload?.key || 'anon';
  const meta = payload?.meta || payload || {};

  config.presenceKey = key;
  subs.set(topic, config);

  // Update state
  if (!presenceState.has(topic)) presenceState.set(topic, new Map());
  const topicState = presenceState.get(topic);
  topicState.set(key, { metas: [{ ...meta, phx_ref: String(Date.now()) }] });

  // Broadcast presence_diff to all subscribers of this topic
  const diff = {
    joins: { [key]: { metas: topicState.get(key).metas } },
    leaves: {},
  };
  broadcastPresenceDiff(topic, diff);

  if (ref) {
    send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
  }
}

function handlePresenceUntrack(ws, topic, ref, subs) {
  const config = subs.get(topic) || {};
  if (config.presenceKey) {
    removePresence(topic, config.presenceKey, ws);
  }
  if (ref) {
    send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
  }
}

function handlePresenceEvent(ws, topic, payload, ref, subs) {
  // Generic presence event — treat as track
  handlePresenceTrack(ws, topic, payload, ref, subs);
}

function removePresence(topic, key, ws) {
  const topicState = presenceState.get(topic);
  if (!topicState) return;

  const leaving = topicState.get(key);
  if (!leaving) return;

  topicState.delete(key);
  if (topicState.size === 0) presenceState.delete(topic);

  // Broadcast leave
  const diff = {
    joins: {},
    leaves: { [key]: { metas: leaving.metas } },
  };
  broadcastPresenceDiff(topic, diff);
}

function broadcastPresenceDiff(topic, diff) {
  wss.clients.forEach((ws) => {
    if (ws.readyState !== 1) return;
    const subs = clientSubs.get(ws);
    if (!subs || !subs.has(topic)) return;

    send(ws, { topic, event: 'presence_diff', payload: diff, ref: null });
  });
}

// ─── Helpers ───────────────────────────────────────────────────────
function send(ws, msg) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify(msg));
  }
}

// ─── Heartbeat / keepalive ─────────────────────────────────────────
const pingInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      ws.terminate();
      return;
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('close', () => clearInterval(pingInterval));

// ─── HTTP upgrade handler for flexible paths ───────────────────────
// Accept /websocket, /v1/websocket, /realtime/v1/websocket, etc.
const server = wss.options.server || wss._server;

// ─── Start ─────────────────────────────────────────────────────────
await connectPg();
console.log('[Realtime] Server ready');
