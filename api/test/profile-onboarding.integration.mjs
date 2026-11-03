// Local database only. Every fixture, including profile edits, is rolled back.
import assert from 'node:assert/strict';
import express from 'express';
import { pool } from '../src/db.js';
import { resolveVkUser } from '../src/routes/auth-vkid.js';
import { resolveYandexUser } from '../src/routes/auth-yandex.js';
import { registerProfileOnboarding } from '../src/routes/auth-profile-onboarding.js';
if (process.env.SECURITY_TEST_LOCAL !== 'yes') throw new Error('Local test opt-in required');
const connection = await pool.connect();
await connection.query('BEGIN');
const transaction = { query: (sql, params) => ['BEGIN','COMMIT','ROLLBACK'].includes(sql) ? Promise.resolve({ rows: [] }) : connection.query(sql, params), release() {} };
const app = express();
app.use(express.json());
let owner;
app.use((req, _res, next) => { if (owner) req.user = { id: owner, role: 'authenticated' }; next(); });
registerProfileOnboarding(app, { query: transaction.query, connect: async () => transaction });
const server = app.listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
const base = 'http://127.0.0.1:' + server.address().port + '/profile-onboarding';
const post = username => fetch(base, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username }) });
let checks = 0;
try {
  assert.equal((await fetch(base)).status, 401); checks++;
  assert.equal((await post('Artist')).status, 401); checks++;
  const suffix = Date.now().toString();
  const first = await resolveVkUser(connection, { consent: true, profile: { subject: suffix, email: `vk-nickname-${suffix}@example.invalid`, name: 'Provider name' } });
  const second = await resolveYandexUser(connection, { consent: true, profile: { subject: suffix, email: `ya-nickname-${suffix}@example.invalid`, name: 'Provider name' } });
  for (const user of [first, second]) {
    owner = user.id;
    assert.deepEqual(await (await fetch(base)).json(), { required: true }); checks++;
    const before = (await connection.query('SELECT balance FROM public.profiles WHERE user_id=$1', [owner])).rows[0].balance;
    assert.equal((await post('<invalid>')).status, 422); checks++;
    const nickname = (user.id === first.id ? 'Артист ' : 'Другой ') + suffix;
    assert.equal((await post(nickname)).status, 200); checks++;
    assert.deepEqual(await (await fetch(base)).json(), { required: false }); checks++;
    const row = (await connection.query('SELECT p.username,p.display_name,p.balance,u.raw_user_meta_data FROM public.profiles p JOIN auth.users u ON u.id=p.user_id WHERE u.id=$1', [owner])).rows[0];
    assert.equal(row.username, nickname); checks++;
    assert.equal(row.display_name, nickname); checks++;
    assert.equal(row.raw_user_meta_data.username, nickname); checks++;
    assert.ok(row.raw_user_meta_data.nickname_selected_at); checks++;
    assert.equal(row.balance, before); checks++;
    assert.equal((await post('Overwrite')).status, 200); checks++;
    assert.equal((await connection.query('SELECT username FROM public.profiles WHERE user_id=$1', [owner])).rows[0].username, nickname); checks++;
  }
  // Recreate the exact legacy state of an already registered Yandex account.
  owner = second.id;
  const legacy = 'ya_' + 'x'.repeat(24);
  await connection.query(`UPDATE auth.users SET raw_user_meta_data=(raw_user_meta_data-'nickname_required'-'nickname_selected_at') || jsonb_build_object('username',$2::text) WHERE id=$1`, [owner, legacy]);
  await connection.query('UPDATE public.profiles SET username=$2 WHERE user_id=$1', [owner, legacy]);
  assert.equal((await (await fetch(base)).json()).required, true); checks++;
  assert.equal((await post('АРТИСТ ' + suffix)).status, 409); checks++;
  assert.equal((await (await fetch(base)).json()).required, true); checks++;
  await connection.query('UPDATE public.profiles SET username=$2 WHERE user_id=$1', [owner, 'Chosen manually']);
  assert.equal((await (await fetch(base)).json()).required, false); checks++;
  assert.equal((await connection.query('SELECT username FROM public.profiles WHERE user_id=$1', [first.id])).rows[0].username, 'Артист ' + suffix); checks++;
  console.log(`Nickname onboarding: ${checks} checks passed; fixtures rolled back.`);
} finally {
  await connection.query('ROLLBACK'); connection.release();
  await new Promise(resolve => server.close(resolve)); await pool.end();
}
