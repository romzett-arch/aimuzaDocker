import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applySupportQaInsertOwnership,
  assertSupportQaMutationAccess,
  assertSupportQaReadAccess,
  filterSupportQaMutationColumns,
  getSupportQaMutationScope,
  getSupportQaReadScope,
} from '../src/security/support-qa-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const moderator = { id: 'mod-1', role: 'authenticated', app_role: 'moderator' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const superAdmin = { id: 'root-1', role: 'authenticated', app_role: 'super_admin' };

test('private support and QA resources require authentication and owner scoping', () => {
  for (const table of ['support_tickets', 'ticket_messages', 'qa_tickets', 'qa_comments']) {
    assert.throws(() => assertSupportQaReadAccess(table, null), error => error.status === 401);
  }
  assert.deepEqual(getSupportQaReadScope('support_tickets', user, 3), {
    sql: '"user_id" = $3', params: ['user-1'],
  });
  assert.match(getSupportQaReadScope('ticket_messages', user, 4).sql, /support_tickets/);
  assert.deepEqual(getSupportQaReadScope('qa_tickets', user, 2), {
    sql: '"reporter_id" = $2', params: ['user-1'],
  });
  assert.deepEqual(getSupportQaReadScope('support_tickets', moderator), { sql: '', params: [] });
});

test('ticket ownership and staff flags are server-controlled', () => {
  assert.deepEqual(
    applySupportQaInsertOwnership('support_tickets', { user_id: 'victim', subject: 'x' }, user),
    { user_id: 'user-1', subject: 'x' },
  );
  assert.deepEqual(
    applySupportQaInsertOwnership('ticket_messages', { user_id: 'victim', is_staff_reply: true }, user),
    { user_id: 'user-1', is_staff_reply: false, is_staff: false },
  );
  assert.equal(applySupportQaInsertOwnership('ticket_messages', {}, moderator).is_staff_reply, true);
});

test('ordinary users cannot mutate server-owned ticket fields', () => {
  assert.deepEqual(
    filterSupportQaMutationColumns('support_tickets', ['subject', 'status', 'assigned_to', 'reward_xp'], user, 'insert'),
    ['subject'],
  );
  assert.deepEqual(
    filterSupportQaMutationColumns('qa_tickets', ['title', 'reporter_id', 'status', 'reward_credits'], user, 'insert'),
    ['title', 'reporter_id'],
  );
  assert.throws(() => assertSupportQaMutationAccess('qa_tester_stats', user, 'update'), error => error.status === 403);
  assert.throws(() => assertSupportQaMutationAccess('qa_tickets', user, 'update'), error => error.status === 403);
  assert.throws(() => assertSupportQaMutationAccess('support_tickets', admin, 'delete'), error => error.status === 403);
  assert.doesNotThrow(() => assertSupportQaMutationAccess('support_tickets', superAdmin, 'delete'));
  assert.deepEqual(getSupportQaMutationScope('support_tickets', user, 5), {
    sql: '"user_id" = $5', params: ['user-1'],
  });
});

test('bounties are public-read but admin-write', () => {
  assert.doesNotThrow(() => assertSupportQaReadAccess('qa_bounties', null));
  assert.match(getSupportQaReadScope('qa_bounties', null).sql, /is_active/);
  assert.throws(() => assertSupportQaMutationAccess('qa_bounties', user, 'insert'), error => error.status === 403);
  assert.doesNotThrow(() => assertSupportQaMutationAccess('qa_bounties', admin, 'insert'));
});

test('notifications remain private even for staff accounts', () => {
  assert.throws(() => assertSupportQaReadAccess('notifications', null), error => error.status === 401);
  assert.deepEqual(getSupportQaReadScope('notifications', user, 3), {
    sql: '"user_id" = $3', params: ['user-1'],
  });
  assert.deepEqual(getSupportQaReadScope('notifications', admin, 4), {
    sql: '"user_id" = $4', params: ['admin-1'],
  });
  assert.deepEqual(getSupportQaMutationScope('notifications', admin, 5), {
    sql: '"user_id" = $5', params: ['admin-1'],
  });
});
