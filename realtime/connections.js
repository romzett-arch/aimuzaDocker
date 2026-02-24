import {
  handleJoin,
  handleLeave,
  handlePresenceTrack,
  handlePresenceUntrack,
  removePresence,
  broadcastPresenceDiff,
} from './channels.js';

export function createConnectionHandler(wss, clientSubs, presenceState, jwt, JWT_SECRET) {
  const sendMsg = (ws, msg) => {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify({
        topic: msg.topic ?? '',
        event: msg.event ?? '',
        payload: msg.payload ?? {},
        ref: msg.ref ?? null,
      }));
    }
  };

  const handleMessage = (ws, msg, subs) => {
    const { topic, event, payload, ref } = msg;

    switch (event) {
      case 'phx_join':
        handleJoin(wss, clientSubs, presenceState, sendMsg, ws, topic, payload, ref, subs);
        break;

      case 'phx_leave':
        handleLeave(wss, clientSubs, presenceState, sendMsg, removePresence, ws, topic, ref, subs);
        break;

      case 'heartbeat':
        sendMsg(ws, { topic: 'phoenix', event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
        break;

      case 'access_token':
        try {
          const token = payload?.access_token || payload;
          if (jwt && JWT_SECRET && typeof token === 'string') {
            const decoded = jwt.verify(token, JWT_SECRET);
            ws.userId = decoded.sub || null;
            ws.userRole = decoded.role || 'authenticated';
          }
          sendMsg(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
        } catch (jwtErr) {
          console.warn('[Realtime] Invalid JWT token:', jwtErr.message);
          sendMsg(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
        }
        break;

      case 'presence':
        handlePresenceTrack(wss, clientSubs, presenceState, sendMsg, broadcastPresenceDiff, ws, topic, payload, ref, subs);
        break;

      case 'presence_track':
        handlePresenceTrack(wss, clientSubs, presenceState, sendMsg, broadcastPresenceDiff, ws, topic, payload, ref, subs);
        break;

      case 'presence_untrack':
        handlePresenceUntrack(wss, clientSubs, presenceState, sendMsg, removePresence, ws, topic, ref, subs);
        break;

      default:
        if (ref) {
          sendMsg(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
        }
    }
  };

  return function handleConnection(ws, req) {
    const clientIp = req.headers['x-real-ip'] || req.socket.remoteAddress || 'unknown';
    console.log(`[Realtime] Client connected from ${clientIp} — total: ${wss.clients.size}`);

    const subs = new Map();
    clientSubs.set(ws, subs);

    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (raw) => {
      try {
        const parsed = JSON.parse(String(raw));
        const msg = Array.isArray(parsed)
          ? { join_ref: parsed[0], ref: parsed[1], topic: parsed[2], event: parsed[3], payload: parsed[4] ?? {} }
          : parsed;
        console.log(`[Realtime] MSG from ${clientIp}: event=${msg.event} topic=${msg.topic} ref=${msg.ref || '-'}`);
        handleMessage(ws, msg, subs);
      } catch (e) {
        console.warn(`[Realtime] Bad message from ${clientIp}:`, String(raw).slice(0, 200));
      }
    });

    ws.on('close', (code, reason) => {
      console.log(`[Realtime] Client disconnected — code=${code} reason=${String(reason).slice(0, 100)}`);
      console.log(`[Realtime] Client disconnected — remaining: ${wss.clients.size - 1}`);
      subs.forEach((config, topic) => {
        if (config.presenceKey) {
          removePresence(wss, clientSubs, presenceState, topic, config.presenceKey, ws);
        }
      });
      clientSubs.delete(ws);
    });
  };
}
