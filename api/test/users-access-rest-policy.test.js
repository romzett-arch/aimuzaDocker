import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertUsersAccessMutation,
  applyUsersAccessInsertOwnership,
  getUsersAccessMutationScope,
  getUsersAccessReadScope,
  isUsersAccessTable,
} from '../src/security/users-access-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('all identity and access tables are explicitly protected', () => {
  for (const table of [
    'user_roles', 'role_invitations', 'role_invitation_permissions',
    'moderator_permissions', 'permission_categories', 'moderator_presets',
    'role_change_logs', 'verification_requests', 'user_blocks',
  ]) assert.equal(isUsersAccessTable(table), true, table);
  assert.equal(isUsersAccessTable('tracks'), false);
});

test('anonymous users cannot read private identity data', () => {
  for (const table of ['user_roles', 'role_invitations', 'verification_requests', 'user_blocks']) {
    assert.throws(() => getUsersAccessReadScope(table, null, 1), error => error.status === 401);
  }
});

test('owner-readable resources are scoped to the authenticated user', () => {
  assert.deepEqual(getUsersAccessReadScope('role_invitations', user, 3), {
    sql: '"user_id" = $3', params: ['user-1'],
  });
  assert.match(getUsersAccessReadScope('role_invitation_permissions', user, 2).sql, /ri\.user_id = \$2/);
  assert.throws(() => getUsersAccessReadScope('role_change_logs', user, 1), error => error.status === 403);
  assert.equal(getUsersAccessReadScope('role_change_logs', admin, 1).sql, '');
});

test('administrative state tables are RPC-only even for admins', () => {
  for (const table of ['user_roles', 'role_invitations', 'moderator_permissions', 'verification_requests', 'user_blocks']) {
    assert.throws(() => assertUsersAccessMutation(table, null, 'insert'), error => error.status === 401);
    assert.throws(() => assertUsersAccessMutation(table, user, 'insert'), error => error.status === 403);
    assert.throws(() => assertUsersAccessMutation(table, admin, 'update'), error => error.code === 'RPC_REQUIRED');
    assert.doesNotThrow(() => assertUsersAccessMutation(table, service, 'delete'));
  }
});

test('audit log is admin append-only', () => {
  assert.doesNotThrow(() => assertUsersAccessMutation('role_change_logs', admin, 'insert'));
  assert.throws(() => assertUsersAccessMutation('role_change_logs', admin, 'delete'), error => error.code === 'AUDIT_APPEND_ONLY');
});

test('profile mutations are bound to the authenticated owner', () => {
  assert.deepEqual(applyUsersAccessInsertOwnership('profiles', { user_id: 'victim', username: 'name' }, user), {
    user_id: 'user-1', username: 'name',
  });
  assert.deepEqual(getUsersAccessMutationScope('profiles', user, 4), {
    sql: '"user_id" = $4', params: ['user-1'],
  });
  assert.doesNotThrow(() => assertUsersAccessMutation('profiles', user, 'update'));
  assert.throws(() => assertUsersAccessMutation('profiles', user, 'delete'), error => error.code === 'RPC_REQUIRED');
});
