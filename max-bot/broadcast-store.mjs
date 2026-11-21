export function createBroadcastStore(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS broadcast_groups (
      id TEXT PRIMARY KEY, title TEXT, active INTEGER NOT NULL, updated INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS broadcasts (
      id TEXT PRIMARY KEY, owner TEXT NOT NULL, input TEXT NOT NULL, results TEXT NOT NULL,
      finished INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL
    );
  `);

  const group = db.prepare(`INSERT INTO broadcast_groups (id,title,active,updated) VALUES (?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET title=COALESCE(excluded.title,broadcast_groups.title),
      active=excluded.active, updated=excluded.updated WHERE excluded.updated>=broadcast_groups.updated`);
  const known = db.prepare("SELECT id,title FROM broadcast_groups WHERE id=? AND active=1");
  const list = db.prepare("SELECT id,title FROM broadcast_groups WHERE active=1 ORDER BY title COLLATE NOCASE,id");
  const create = db.prepare("INSERT OR IGNORE INTO broadcasts (id,owner,input,results,created) VALUES (?,?,?,?,?)");
  const get = db.prepare("SELECT * FROM broadcasts WHERE id=? AND owner=?");
  const next = db.prepare("SELECT * FROM broadcasts WHERE finished=0 ORDER BY rowid LIMIT 1");
  const save = db.prepare("UPDATE broadcasts SET results=?,finished=? WHERE id=?");
  const prune = db.prepare("DELETE FROM broadcasts WHERE finished=1 AND created<?");

  function read(row) {
    return row && { id: row.id, input: JSON.parse(row.input), results: JSON.parse(row.results), done: Boolean(row.finished) };
  }

  return {
    group: (id, name, active, timestamp) => group.run(id, name, Number(active), timestamp),
    knownGroup: id => known.get(id),
    groups: () => list.all(),
    start(id, owner, input, results) {
      create.run(id, owner, JSON.stringify(input), JSON.stringify(results), Date.now());
      return read(get.get(id, owner));
    },
    get: (id, owner) => read(get.get(id, owner)),
    next: () => read(next.get()),
    save: batch => save.run(JSON.stringify(batch.results), Number(batch.done), batch.id),
    prune: () => prune.run(Date.now() - 7 * 86_400_000),
  };
}
