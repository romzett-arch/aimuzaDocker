import { canSubscribe } from './security.js';
import {
  handleJoin,
  handleLeave,
  handlePresenceTrack,
  handlePresenceUntrack,
  removePresence,
  broadcastPresenceDiff,
} from './channels.js';

export function createConnectionHandler(wss, clientSubs, presenceState, jwt, JWT_SECRET, security) {
  const clearSubscriptions=(ws,subs)=>{
    for(const [topic,config] of subs) if(config.presenceKey) removePresence(wss,clientSubs,presenceState,topic,config.presenceKey,ws);
    subs.clear();
  };
  const sendMsg = (ws, msg) => {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify([
        msg.join_ref ?? null,
        msg.ref ?? null,
        msg.topic ?? '',
        msg.event ?? '',
        msg.payload ?? {},
      ]));
    }
  };

  const handleMessage = async (ws, msg, subs) => {
    let { topic, event, payload, ref } = msg;

    switch (event) {
      case 'phx_join':
        try {
          const token=payload?.access_token || ws.token;
          const identity=token ? await security.validate(token) : null;
          if(ws.user?.id!==identity?.id) clearSubscriptions(ws,subs);
          ws.user=identity; ws.token=token||null;
          ws.joinAuthorized=(payload?.config?.postgres_changes||[]).every(c=>canSubscribe(c.table,c.schema||'public',ws.user));
          if ((payload?.config?.presence || /presence|typing|online/.test(topic)) && !(await security.presenceAllowed(ws.user,topic))) ws.joinAuthorized=false;
          if (payload?.config?.presence && ws.user) payload.config.presence.key=ws.user.id;
          if ((payload?.config?.postgres_changes || []).length > 20) ws.joinAuthorized=false;
        } catch {ws.user=null;ws.token=null;ws.joinAuthorized=false;}

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
          const token=payload?.access_token||payload,identity=await security.validate(token);
          if(ws.user?.id!==identity?.id) clearSubscriptions(ws,subs);
          ws.token=token;ws.user=identity;
        }
        catch { clearSubscriptions(ws,subs);ws.token=null;ws.user=null; }
        break;

      case 'presence':
      case 'track':
        if (!ws.token || !(ws.user = await security.validate(ws.token))) break;
        if(!subs.has(topic) || !(await security.presenceAllowed(ws.user,topic))) break;
        payload={...(payload||{}),key:ws.user.id};
        handlePresenceTrack(wss, clientSubs, presenceState, sendMsg, broadcastPresenceDiff, ws, topic, payload, ref, subs);
        break;

      case 'presence_track':
        if (!ws.token || !(ws.user = await security.validate(ws.token))) break;
        if(!subs.has(topic) || !(await security.presenceAllowed(ws.user,topic))) break;
        payload={...(payload||{}),key:ws.user.id};
        handlePresenceTrack(wss, clientSubs, presenceState, sendMsg, broadcastPresenceDiff, ws, topic, payload, ref, subs);
        break;

      case 'presence_untrack':
      case 'untrack':
        handlePresenceUntrack(wss, clientSubs, presenceState, sendMsg, removePresence, ws, topic, ref, subs);
        break;

      default:
        if (ref) {
          sendMsg(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
        }
    }
  };

  return function handleConnection(ws, req) {
    ws.authorizePresence=async topic=>{
      if(!ws.token) return false;
      try {ws.user=await security.validate(ws.token);return await security.presenceAllowed(ws.user,topic);}catch{return false;}
    };
    if (wss.clients.size > 1000) { ws.close(1013,'Capacity reached'); return; }
    const clientIp = req.headers['x-real-ip'] || req.socket.remoteAddress || 'unknown';
    console.log(`[Realtime] Client connected from ${clientIp} — total: ${wss.clients.size}`);

    const subs = new Map();
    clientSubs.set(ws, subs);

    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (raw) => {
      const now=Date.now();
      if (!ws.rateStart || now-ws.rateStart>=10000) {ws.rateStart=now;ws.rateCount=0;}
      if (++ws.rateCount>100) {ws.close(1008,'Rate limit');return;}
      try {
        const parsed = JSON.parse(String(raw));
        const msg = Array.isArray(parsed)
          ? { join_ref: parsed[0], ref: parsed[1], topic: parsed[2], event: parsed[3], payload: parsed[4] ?? {} }
          : parsed;
        console.log(`[Realtime] MSG from ${clientIp}: event=${msg.event} topic=${msg.topic} ref=${msg.ref || '-'}`);
        void handleMessage(ws, msg, subs).catch(()=>ws.close(1008,'Access denied'));
      } catch (e) {
        console.warn('[Realtime] Invalid message');
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
