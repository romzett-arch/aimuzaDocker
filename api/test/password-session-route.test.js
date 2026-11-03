import test from 'node:test';
import assert from 'node:assert/strict';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';

process.env.JWT_SECRET = 'password-session-tests-only-secret-longer-than-32';
const { registerPassword } = await import('../src/routes/auth-password.js');

function fixture({ version = 0, failRefresh = false } = {}) {
  const queries = [];
  const user = { id: 'user-1', email: 'social@example.invalid', email_confirmed_at: new Date(),
    raw_user_meta_data: { provider: 'vkid', session_version: version } };
  const client = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      if (sql.includes('SELECT * FROM auth.users')) return { rows: [user] };
      if (sql.includes('UPDATE auth.users')) return { rows: [{ ...user, raw_user_meta_data: { ...user.raw_user_meta_data, session_version: params[2] } }] };
      if (sql.includes('FROM public.user_roles')) return { rows: [{ role: 'moderator' }] };
      if (failRefresh && sql.includes('INSERT INTO public.api_refresh_sessions')) throw Error('database unavailable');
      return { rows: [] };
    },
    release() { queries.push({ sql: 'RELEASE' }); },
  };
  let connects = 0, handlers;
  registerPassword({ post(path, ...registered) { assert.equal(path, '/password'); handlers = registered; } },
    { async connect() { connects++; return client; } });
  const res = { statusCode: 200, headers: {}, set(key, value) { this.headers[key] = value; return this; },
    status(code) { this.statusCode = code; return this; }, json(body) { this.body = body; return this; } };
  return { queries, res, user, handler: handlers.at(-1), requireAuth: handlers[0], connects: () => connects };
}

for (const origin of ['vkid', 'yandex', 'direct', 'legacy']) {
  test(`password renewal preserves ${origin} origin and revokes other sessions atomically`, async () => {
    const f = fixture();
    await f.handler({ user: { id: f.user.id, role: 'authenticated', session_version: 0, session_origin: origin }, body: { password: 'NewPassword!9' } }, f.res);
    assert.equal(f.res.statusCode, 200);
    assert.equal(f.res.headers['Cache-Control'], 'no-store');
    const claims = jwt.verify(f.res.body.access_token, process.env.JWT_SECRET);
    assert.equal(claims.session_origin, origin);
    assert.equal(claims.session_version, 1);
    assert.equal(claims.app_role, 'moderator');
    const update = f.queries.find(q => q.sql.includes('UPDATE auth.users'));
    assert(await bcrypt.compare('NewPassword!9', update.params[1]));
    const refresh = f.queries.find(q => q.sql.includes('INSERT INTO public.api_refresh_sessions'));
    assert.equal(refresh.params[2], 1);
    assert.equal(refresh.params[3], origin);
    assert.notEqual(refresh.params[0], f.res.body.refresh_token);
    assert.equal(f.res.body.user.user_metadata.provider, 'vkid');
    assert(!('encrypted_password' in f.res.body.user));
    assert.deepEqual(f.queries.map(q => q.sql.trim().split(/\s+/).slice(0, 3).join(' ')),
      ['BEGIN', 'SELECT * FROM', 'UPDATE auth.users SET', 'DELETE FROM public.api_refresh_sessions', 'SELECT role::text AS', 'INSERT INTO public.api_refresh_sessions(token_hash,user_id,session_version,expires_at,session_origin)', 'COMMIT', 'RELEASE']);
  });
}

test('refresh creation failure rolls back the password and session changes', async () => {
  const f = fixture({ failRefresh: true });
  await f.handler({ user: { id: f.user.id, role: 'authenticated', session_version: 0 }, body: { password: 'NewPassword!9' } }, f.res);
  assert.equal(f.res.statusCode, 503);
  assert(!f.res.body.access_token);
  assert.equal(f.queries.at(-2).sql, 'ROLLBACK');
  assert(!f.queries.some(q => q.sql === 'COMMIT'));
});

test('a session revoked during hashing cannot change the password', async () => {
  const f = fixture({ version: 1 });
  await f.handler({ user: { id: f.user.id, role: 'authenticated', session_version: 0 }, body: { password: 'NewPassword!9' } }, f.res);
  assert.equal(f.res.statusCode, 401);
  assert(!f.queries.some(q => q.sql.includes('UPDATE auth.users')));
  assert.equal(f.queries.at(-2).sql, 'ROLLBACK');
});

test('anonymous, service, impersonation and weak-password requests cannot change credentials', async () => {
  const anon = fixture();
  anon.requireAuth({ user: null }, anon.res, () => assert.fail('Anonymous request accepted'));
  assert.equal(anon.res.statusCode, 401);
  for (const user of [{ role: 'service_role' }, { role: 'authenticated', session_origin: 'impersonation' }]) {
    const f = fixture();
    await f.handler({ user, body: { password: 'NewPassword!9' } }, f.res);
    assert.equal(f.res.statusCode, 403);
    assert.equal(f.connects(), 0);
  }
  const weak = fixture();
  await weak.handler({ user: { role: 'authenticated' }, body: { password: 'weak' } }, weak.res);
  assert.equal(weak.res.statusCode, 400);
  assert.equal(weak.connects(), 0);
});
