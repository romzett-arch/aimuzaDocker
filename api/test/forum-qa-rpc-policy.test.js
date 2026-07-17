import test from 'node:test';
import assert from 'node:assert/strict';
import { assertForumRpcAccess } from '../src/security/forum-rpc-policy.js';
import { assertQaRpcAccess } from '../src/security/qa-rpc-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const moderator = { id: 'moderator-1', role: 'authenticated', app_role: 'moderator' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('forum topic cascade deletion is staff-only and binds the moderator identity', () => {
  assert.throws(() => assertForumRpcAccess('delete_forum_topic_cascade', null, {}), error => error.status === 401);
  assert.throws(() => assertForumRpcAccess('delete_forum_topic_cascade', user, {}), error => error.status === 403);

  for (const actor of [moderator, admin]) {
    const params = { p_topic_id: 'topic-1', p_moderator_id: 'victim' };
    assertForumRpcAccess('delete_forum_topic_cascade', actor, params);
    assert.equal(params.p_moderator_id, actor.id);
  }

  const serviceParams = { p_topic_id: 'topic-1', p_moderator_id: 'admin-1' };
  assertForumRpcAccess('delete_forum_topic_cascade', service, serviceParams);
  assert.equal(serviceParams.p_moderator_id, 'admin-1');
});

test('QA report increments require authentication and bind the user identity', () => {
  assert.throws(() => assertQaRpcAccess('qa_increment_reports_total', null, {}), error => error.status === 401);

  const params = { p_user_id: 'victim' };
  assertQaRpcAccess('qa_increment_reports_total', user, params);
  assert.equal(params.p_user_id, user.id);

  const serviceParams = { p_user_id: 'target-user' };
  assertQaRpcAccess('qa_increment_reports_total', service, serviceParams);
  assert.equal(serviceParams.p_user_id, 'target-user');
});

test('QA resolution is staff-only and support ticket creation requires authentication', () => {
  assert.throws(() => assertQaRpcAccess('resolve_qa_ticket', user, {}), error => error.status === 403);
  assert.doesNotThrow(() => assertQaRpcAccess('resolve_qa_ticket', moderator, {}));
  assert.doesNotThrow(() => assertQaRpcAccess('resolve_qa_ticket', admin, {}));
  assert.throws(() => assertQaRpcAccess('create_support_ticket', null, {}), error => error.status === 401);
  assert.doesNotThrow(() => assertQaRpcAccess('create_support_ticket', user, {}));
});

test('support-to-QA promotion is staff-only', () => {
  assert.throws(() => assertQaRpcAccess('promote_support_ticket_to_qa', null, {}), error => error.status === 401);
  assert.throws(() => assertQaRpcAccess('promote_support_ticket_to_qa', user, {}), error => error.status === 403);
  assert.doesNotThrow(() => assertQaRpcAccess('promote_support_ticket_to_qa', moderator, {}));
  assert.doesNotThrow(() => assertQaRpcAccess('promote_support_ticket_to_qa', admin, {}));
  assert.doesNotThrow(() => assertQaRpcAccess('promote_support_ticket_to_qa', service, {}));
});
