import './safe-logging.js';
/**
 * AI Planet Sound — Realtime WebSocket Server
 *
 * Совместим с Supabase Realtime (Phoenix channels protocol).
 * Слушает PostgreSQL LISTEN/NOTIFY и рассылает события подписчикам.
 * Поддерживает postgres_changes и presence.
 */

import { WebSocketServer } from 'ws';
import pg from 'pg';
import { createRealtimeSecurity, publicRecord } from './security.js';
import { broadcastChange } from './channels.js';
import { createConnectionHandler } from './connections.js';

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
  password: process.env.DB_PASSWORD,
  client_encoding: 'UTF8',
};

const presenceState = new Map();
const clientSubs = new WeakMap();

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
          void broadcastChange(wss,clientSubs,data,security.readable).catch(()=>console.warn('[Realtime] Event denied'));
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

const accessPool=new pg.Pool({...DB_CONFIG,max:5,statement_timeout:5000});
const security=createRealtimeSecurity(accessPool,jwt,JWT_SECRET);
const wss = new WebSocketServer({ port: WS_PORT, path: '/websocket', maxPayload:65536, perMessageDeflate:false });

const handleConnection = createConnectionHandler(wss, clientSubs, presenceState, jwt, JWT_SECRET, security);
wss.on('connection', handleConnection);

wss.on('listening', () => {
  console.log(`[Realtime] WebSocket listening on :${WS_PORT}/websocket`);
});

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

await connectPg();
console.log('[Realtime] Server ready');
