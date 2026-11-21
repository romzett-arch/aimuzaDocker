import { DatabaseSync } from "node:sqlite";

export function createChatStore(path) {
  const db = new DatabaseSync(path);
  db.exec(`
    CREATE TABLE IF NOT EXISTS updates (key TEXT PRIMARY KEY, seen_at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS updates_seen_at ON updates (seen_at);
    CREATE TABLE IF NOT EXISTS inbox (key TEXT PRIMARY KEY, event TEXT NOT NULL, due INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS chat_state (id TEXT PRIMARY KEY, state TEXT NOT NULL, touched INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, data TEXT NOT NULL, due INTEGER NOT NULL, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS user_settings (id TEXT PRIMARY KEY, data TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS photo_references (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, photo BLOB NOT NULL, type TEXT NOT NULL, created INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS inbox_due ON inbox (due);
    CREATE INDEX IF NOT EXISTS jobs_due ON jobs (due);
  `);

  return {
    enqueue(event) {
      db.prepare("INSERT OR IGNORE INTO inbox(key,event,due) SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM updates WHERE key=?)")
        .run(event.key, JSON.stringify(event), Date.now(), event.key);
    },
    nextEvent() {
      const row = db.prepare("SELECT key,event,attempts FROM inbox WHERE due<=? ORDER BY due,rowid LIMIT 1").get(Date.now());
      return row && { ...row, event: JSON.parse(row.event) };
    },
    finishEvent(key) {
      db.exec("BEGIN");
      try {
        db.prepare("INSERT OR IGNORE INTO updates VALUES (?,?)").run(key, Date.now());
        db.prepare("DELETE FROM inbox WHERE key=?").run(key);
        db.exec("COMMIT");
      } catch (error) { db.exec("ROLLBACK"); throw error; }
    },
    retryEvent(key, delay) {
      db.prepare("UPDATE inbox SET due=?,attempts=attempts+1 WHERE key=?").run(Date.now() + delay,key);
    },
    state(userId) {
      const row = db.prepare("SELECT state FROM chat_state WHERE id=? AND touched>?").get(String(userId), Date.now() - 3_600_000);
      return row ? JSON.parse(row.state) : {};
    },
    setState(userId, state) {
      db.prepare("INSERT INTO chat_state VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,touched=excluded.touched")
        .run(String(userId), JSON.stringify(state), Date.now());
    },
    // Последний просмотренный/полученный текст песни — живёт сутки независимо
    // от текущего шага диалога, чтобы «Сгенерировать трек» работал от любой кнопки.
    lastLyrics(userId) {
      const row = db.prepare("SELECT state FROM chat_state WHERE id=? AND touched>?").get(`${userId}:lyrics`, Date.now() - 86_400_000);
      return row ? JSON.parse(row.state) : null;
    },
    setLastLyrics(userId, value) {
      db.prepare("INSERT INTO chat_state VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,touched=excluded.touched")
        .run(`${userId}:lyrics`, JSON.stringify(value), Date.now());
    },
    // Постоянные настройки чата (например, «не напоминать про сайт»).
    setting(userId) {
      const row = db.prepare("SELECT data FROM user_settings WHERE id=?").get(String(userId));
      return row ? JSON.parse(row.data) : {};
    },
    setSetting(userId, patch) {
      db.prepare("INSERT INTO user_settings VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data")
        .run(String(userId), JSON.stringify({...this.setting(userId), ...patch}));
    },
    addJob(job) {
      db.prepare("INSERT OR IGNORE INTO jobs VALUES (?,?,?,?)").run(job.id, JSON.stringify(job), Date.now(), Date.now());
    },
    nextJob() {
      const row = db.prepare("SELECT * FROM jobs WHERE due<=? ORDER BY due,rowid LIMIT 1").get(Date.now());
      return row && { ...JSON.parse(row.data), created:row.created };
    },
    saveJob(job, delay=0) {
      db.prepare("UPDATE jobs SET data=?,due=? WHERE id=?").run(JSON.stringify(job),Date.now()+delay,job.id);
    },
    finishJob(id) { db.prepare("DELETE FROM jobs WHERE id=?").run(id); },
    pendingOrder(userId) {
      const row = db.prepare("SELECT state FROM chat_state WHERE id=? AND touched>?").get(`${userId}:payment`, Date.now() - 86_400_000);
      return row ? JSON.parse(row.state) : null;
    },
    deferOrder(job) {
      db.exec("BEGIN");
      try {
        this.setState(`${job.event.userId}:payment`, job);
        this.finishJob(job.id);
        db.exec("COMMIT");
      } catch (error) { db.exec("ROLLBACK"); throw error; }
    },
    clearPendingOrder(userId, id) {
      db.prepare("DELETE FROM chat_state WHERE id=? AND json_extract(state,'$.id')=?").run(`${userId}:payment`, id);
    },
    saveReference(userId, id, { bytes, type }) {
      db.prepare("INSERT INTO photo_references VALUES (?,?,?,?,?)").run(id, String(userId), bytes, type, Date.now());
    },
    reference(userId, id) {
      const row = db.prepare("SELECT photo,type FROM photo_references WHERE id=? AND user_id=?").get(id, String(userId));
      return row && new Blob([row.photo], { type: row.type });
    },
    prune() {
      db.prepare("DELETE FROM updates WHERE seen_at<?").run(Date.now() - 7 * 86_400_000);
      db.prepare("DELETE FROM chat_state WHERE touched<?").run(Date.now() - 86_400_000);
      db.prepare("DELETE FROM photo_references WHERE created<?").run(Date.now() - 2 * 86_400_000);
    },
    close: () => db.close(),
  };
}
