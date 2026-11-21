import { DatabaseSync } from 'node:sqlite';
import { createAimuzaClient } from './aimuza.mjs';
import { createMaxClient } from './max-api.mjs';
import { maxIdentity } from './max-identity.mjs';

const token = process.env.MAX_BOT_TOKEN?.trim();
const internal = process.env.MAX_INTERNAL_SECRET?.trim();
const database = process.env.MAX_BOT_DB;
if (!token || !internal || !database) throw new Error('MAX bot token, internal secret and database are required');

const db = new DatabaseSync(database, { readOnly: true });
const max = createMaxClient(token);
const api = createAimuzaClient(process.env.MAX_AIMUZA_API ?? 'http://api:3000', internal);

try {
  const rows = db.prepare(`SELECT substr(key,9) AS id, seen_at FROM updates
    WHERE key LIKE 'message:%' ORDER BY seen_at DESC LIMIT 300`).all();
  const acceptedAt = new Map(rows.map(({ id, seen_at }) => [id, seen_at]));
  const identities = new Map();
  for (let offset = 0; offset < rows.length; offset += 40) {
    const { messages } = await max.messages(rows.slice(offset, offset + 40).map(row => row.id));
    for (const message of messages ?? []) {
      const user = message.sender;
      const accepted = acceptedAt.get(message.body?.mid);
      if (!accepted || message.recipient?.chat_type !== 'dialog' || user?.is_bot ||
          !Number.isSafeInteger(user?.user_id) || user.user_id < 1) continue;
      const identity = maxIdentity(user, message.timestamp ?? accepted);
      const previous = identities.get(user.user_id);
      if (!previous || previous.observedAt < identity.observedAt) identities.set(user.user_id, identity);
    }
  }
  let count = 0;
  for (const [userId, identity] of identities) {
    const { updated } = await api('identity', { userId }, { identity });
    if (updated) count++;
  }
  console.info('MAX profiles updated:', count);
} finally {
  db.close();
}
