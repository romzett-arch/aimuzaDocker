import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyMusicInsertOwnership,
  assertMusicMutationAccess,
  getMusicMutationScope,
  getMusicReadScope,
} from '../src/security/music-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };

test('track addon reads are private and owner scoped', () => {
  assert.equal(getMusicReadScope('track_addons', null).sql, 'FALSE');
  const scope = getMusicReadScope('track_addons', user, 3);
  assert.match(scope.sql, /track_id/);
  assert.match(scope.sql, /\$3/);
  assert.deepEqual(scope.params, ['user-1']);
});

test('inactive addon services are hidden from ordinary clients', () => {
  assert.equal(getMusicReadScope('addon_services', null).sql, '"is_active" IS TRUE');
  assert.equal(getMusicReadScope('addon_services', admin).sql, '');
});

test('users may request safe addons but cannot mutate their state', () => {
  assert.doesNotThrow(() => assertMusicMutationAccess('track_addons', user, 'insert'));
  assert.throws(() => assertMusicMutationAccess('track_addons', user, 'update'), /server managed/);
  assert.throws(() => assertMusicMutationAccess('track_addons', user, 'delete'), /server managed/);
  assert.deepEqual(applyMusicInsertOwnership('track_addons', {
    user_id: 'victim', status: 'completed', result_url: 'https://attacker.invalid',
  }, user), {
    user_id: 'user-1', status: 'pending', result_url: null,
  });
  assert.match(getMusicMutationScope('track_addons', user, 5).sql, /\$5/);
});

