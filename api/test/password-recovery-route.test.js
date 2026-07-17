import test from 'node:test';
import assert from 'node:assert/strict';

process.env.JWT_SECRET = 'test-only-jwt-secret-that-is-longer-than-32-characters';

const { pool } = await import('../src/db.js');
const { registerRecovery } = await import('../src/routes/auth-recovery.js');

function createResponse() {
  return {
    statusCode: 200,
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

function getRecoverHandler() {
  let handler;
  const router = {
    post(path, ...handlers) {
      if (path === '/recover') handler = handlers.at(-1);
    },
  };
  registerRecovery(router);
  return handler;
}

test('recovery atomically changes the password and consumes every reset token', async () => {
  const queries = [];
  const client = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      if (sql.includes('FROM public.email_verifications')) {
        return { rows: [{ id: 'verification-1', email: 'user@example.com' }] };
      }
      if (sql.includes('UPDATE auth.users')) return { rows: [{ id: 'user-1' }] };
      return { rows: [] };
    },
    release() {
      queries.push({ sql: 'RELEASE', params: [] });
    },
  };
  const originalConnect = pool.connect;
  pool.connect = async () => client;

  try {
    const res = createResponse();
    await getRecoverHandler()(
      { body: { token: 'ab'.repeat(32), password: 'Strong!1' } },
      res
    );

    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { success: true });
    assert.deepEqual(
      queries.map(({ sql }) => sql.trim().split(/\s+/).slice(0, 3).join(' ')),
      ['BEGIN', 'SELECT id, email', 'UPDATE auth.users SET', 'DELETE FROM public.email_verifications', 'COMMIT', 'RELEASE']
    );
    assert.notEqual(queries[2].params[0], 'Strong!1');
    assert.match(queries[2].params[0], /^\$2[aby]\$/);
  } finally {
    pool.connect = originalConnect;
  }
});

test('expired or already used recovery tokens cannot change a password', async () => {
  const queries = [];
  const client = {
    async query(sql) {
      queries.push(sql);
      if (sql.includes('FROM public.email_verifications')) return { rows: [] };
      return { rows: [] };
    },
    release() {},
  };
  const originalConnect = pool.connect;
  pool.connect = async () => client;

  try {
    const res = createResponse();
    await getRecoverHandler()(
      { body: { token: 'cd'.repeat(32), password: 'Strong!1' } },
      res
    );

    assert.equal(res.statusCode, 400);
    assert.equal(queries.some((sql) => sql.includes('UPDATE auth.users')), false);
    assert.equal(queries.at(-1), 'ROLLBACK');
  } finally {
    pool.connect = originalConnect;
  }
});
