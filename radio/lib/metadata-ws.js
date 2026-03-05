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
    this.wss = new WebSocket.Server({ server, path: '/ws' });
    this.clients = new Set();
    this.currentTrack = null;
    this.queue = [];
    this.listenersCount = 0;

    this.wss.on('connection', (ws, req) => {
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
        try {
          const msg = JSON.parse(raw);
          this.handleMessage(ws, msg);
        } catch (e) {
          console.warn('[WS] Bad message:', String(raw).slice(0, 200));
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

  handleMessage(ws, msg) {
    switch (msg.type) {
      case 'heartbeat':
        this.sendTo(ws, { type: 'heartbeat_ack' });
        break;
      case 'reaction':
        if (this.onReaction) this.onReaction(ws, msg.data);
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
            const decoded = jwt.verify(token, this.jwtSecret);
            if (decoded.sub === userId || decoded.user_id === userId) {
              ws.userId = userId;
              ws.token = token;
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
          ws.userId = userId;
          ws.token = token;
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
