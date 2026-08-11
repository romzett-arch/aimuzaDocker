import test from 'node:test';
import assert from 'node:assert/strict';
import { assertModerationRpcAccess } from '../src/security/moderation-rpc-policy.js';
import {
  assertMusicMutationAccess,
  filterMusicMutationColumns,
  getMusicReadScope,
} from '../src/security/music-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const moderator = { id: 'moderator-1', role: 'authenticated', app_role: 'moderator', permissions: ['moderation'] };
const restrictedModerator = { id: 'moderator-2', role: 'authenticated', app_role: 'moderator', permissions: [] };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('moderation decisions and admin reporting are staff-only', () => {
  for (const fn of ['moderate_track', 'request_track_copyright_evidence', 'resolve_copyright_request', 'get_admin_moderation_stats']) {
    assert.throws(() => assertModerationRpcAccess(fn, null), (error) => error.status === 401);
    assert.throws(() => assertModerationRpcAccess(fn, user), (error) => error.status === 403);
    assert.throws(() => assertModerationRpcAccess(fn, restrictedModerator), (error) => error.status === 403);
    assert.doesNotThrow(() => assertModerationRpcAccess(fn, moderator));
    assert.doesNotThrow(() => assertModerationRpcAccess(fn, admin));
  }
});

test('user moderation commands require authentication', () => {
  for (const fn of ['submit_track_for_moderation', 'respond_copyright_request']) {
    assert.throws(() => assertModerationRpcAccess(fn, null), (error) => error.status === 401);
    assert.doesNotThrow(() => assertModerationRpcAccess(fn, user));
  }
});

test('moderation tables are private and RPC-only', () => {
  assert.equal(getMusicReadScope('copyright_requests', null).sql, 'FALSE');
  assert.match(getMusicReadScope('copyright_requests', user, 4).sql, /\$4/);
  assert.equal(getMusicReadScope('track_health_reports', moderator).sql, '');
  assert.equal(getMusicReadScope('moderation_events', admin).sql, '');
  assert.throws(() => assertMusicMutationAccess('copyright_requests', user, 'insert'), /server command/);
  assert.throws(() => assertMusicMutationAccess('track_health_reports', moderator, 'update'), /server command/);
  assert.doesNotThrow(() => assertMusicMutationAccess('track_health_reports', service, 'update'));
});

test('regular track updates cannot change publication workflow status', () => {
  const columns = filterMusicMutationColumns('tracks', ['title', 'status', 'is_public', 'moderation_status'], user);
  assert.deepEqual(columns, ['title', 'is_public']);
});
