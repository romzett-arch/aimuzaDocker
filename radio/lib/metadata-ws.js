/**
 * Metadata WebSocket Server
 * Sends real-time track info, queue updates, listener counts to clients
 * Auth: при наличии JWT_SECRET проверяет токен перед установкой userId
 */

const WebSocket = require('ws');
const jwt = require('jsonwebtoken');

class MetadataServer {
  constructor(server, options = {}) {
    this.jwtSecret = options.jwtSecret || process.env.JWT_SECRET || null;
    this.validateSession = options.validateSession || (async () => false);
    this.wss = new WebSocket.Server({ server, path: '/ws', maxPayload: 16384, perMessageDeflate: false });
    this.clients = new Set();
    this.currentTrack = null;
    this.queue = [];
    this.listenersCount = 0;

    this.wss.on('connection', (ws, req) => {
      if (this.clients.size >= 1000) {ws.close(1013, 'Capacity reached');return;}
      ws.connectedAt=Date.now(); ws.lastReactionAt=Date.now();
      this.clients.add(ws);
      console.log(`[WS] Client connected — total: ${this.clients.size}`);

      this.sendTo(ws, {
        type: 'init',
        data: {
          current_track: this.currentTrack,
          queue: this.queue.slice(0, 20),
          listeners_count: this.listenersCount,
        },
      });

      ws.isAlive = true;
      ws.on('pong', () => { ws.isAlive = true; });

      ws.on('message', (raw) => {
        const now=Date.now();
        if (!ws.rateStart || now-ws.rateStart>=10000) {ws.rateStart=now;ws.rateCount=0;}
        if (++ws.rateCount>50) {ws.close(1008,'Rate limit');return;}
        try {
          const msg = JSON.parse(raw);
          void this.handleMessage(ws, msg).catch(()=>{ws.userId=null;ws.token=null;});
        } catch (e) {
          console.warn('[WS] Invalid message');
        }
      });

      ws.on('close', () => {
        this.clients.delete(ws);
        console.log(`[WS] Client disconnected — total: ${this.clients.size}`);
      });
    });

    setInterval(() => {
      this.wss.clients.forEach((ws) => {
        if (!ws.isAlive) { ws.terminate(); return; }
        ws.isAlive = false;
        ws.ping();
      });
    }, 30000);
  }

  async handleMessage(ws, msg) {
    switch (msg.type) {
      case 'heartbeat':
        this.sendTo(ws, { type: 'heartbeat_ack' });
        break;
      case 'reaction':
        if (!ws.token || !this.jwtSecret) return;
        try {
          const claims=jwt.verify(ws.token,this.jwtSecret,{algorithms:['HS256']});
          if (claims.sub!==ws.userId || !(await this.validateSession(claims))) return;
        } catch {ws.userId=null;ws.token=null;return;}
        if (this.onReaction) await this.onReaction(ws, msg.data || {});
        break;
      case 'auth': {
        const userId = msg.data?.user_id || null;
        const token = msg.data?.token || null;
        if (!userId) {
          ws.userId = null;
          ws.token = null;
          break;
        }
        if (this.jwtSecret && token) {
          try {
            const decoded = jwt.verify(token, this.jwtSecret, { algorithms: ['HS256'] });
            if (decoded.sub === userId && await this.validateSession(decoded)) {
              ws.userId = userId;
              ws.token = token;
              ws.lastReactionAt=Date.now();
            } else {
              ws.userId = null;
              ws.token = null;
              console.warn('[WS] Auth: user_id mismatch');
            }
          } catch (err) {
            ws.userId = null;
            ws.token = null;
            console.warn('[WS] Auth: invalid token');
          }
        } else {
          ws.userId = null;
          ws.token = null;
        }
        break;
      }
      default:
        break;
    }
  }

  sendTo(ws, msg) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg));
    }
  }

  broadcast(msg) {
    const data = JSON.stringify(msg);
    this.clients.forEach((ws) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(data);
      }
    });
  }

  setCurrentTrack(track) {
    this.trackStartedAt=Date.now();
    this.currentTrack = track;
    this.broadcast({ type: 'track_changed', data: track });
  }

  setQueue(queue) {
    this.queue = queue;
    this.broadcast({ type: 'queue_updated', data: { queue: queue.slice(0, 20) } });
  }

  setListenersCount(count) {
    this.listenersCount = count;
    this.broadcast({ type: 'listeners_count', data: { count } });
  }

  sendAdBreak(adData) {
    this.broadcast({ type: 'ad_break', data: adData });
  }

  sendXpAwarded(userId, xpData) {
    this.clients.forEach((ws) => {
      if (ws.readyState === WebSocket.OPEN && ws.userId === userId) {
        ws.send(JSON.stringify({ type: 'xp_awarded', data: xpData }));
      }
    });
  }
}

module.exports = { MetadataServer };
