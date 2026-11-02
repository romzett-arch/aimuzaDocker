import test from 'node:test';
import assert from 'node:assert/strict';
import { assertMediaSigningAccess } from '../src/security/storage-sign-policy.js';
import { assertOwnedMediaPath } from '../src/security/storage-path-policy.js';

const user = { id: 'owner', role: 'authenticated', app_role: 'user' };
const archive = 'release-packages/a8d4855e-1be5-45fb-bf30-d7a51984c1c4/release-package-audio-v3.zip';

test('generated ZIP signing uses exact release association and caller permissions', async () => {
  const client = { query: async (sql, params) => {
    assert.match(sql, /release\.user_id = \$4/);
    assert.deepEqual(params, ['tracks', archive, false, user.id]);
    return { rowCount: 1 };
  } };
  await assertMediaSigningAccess(user, 'tracks', archive, client);
  await assert.rejects(() => assertMediaSigningAccess(user, 'tracks', archive, {
    query: async () => ({ rowCount: 0 }),
  }), { status: 403 });
});

test('admin signing still requires a registered release archive', async () => {
  const admin = { ...user, app_role: 'admin' };
  await assertMediaSigningAccess(admin, 'tracks', archive, { query: async (sql, params) => {
    assert.equal(params[2], true);
    return { rowCount: 1 };
  } });
  await assert.rejects(() => assertMediaSigningAccess(admin, 'tracks', archive, {
    query: async () => ({ rowCount: 0 }),
  }), { status: 403 });
});

test('signing exception grants no upload/delete access or access to other generated files', async () => {
  assert.throws(() => assertOwnedMediaPath(user, 'tracks', archive));
  for (const filePath of [archive.replace('.zip', '.wav'), `../${archive}`, archive.replace('/release-package', '/../release-package')]) {
    await assert.rejects(() => assertMediaSigningAccess(user, 'tracks', filePath, {
      query: async () => { throw new Error('must not query'); },
    }), { status: 403 });
  }
  await assertMediaSigningAccess(user, 'tracks', 'owner/song.mp3', {});
});
