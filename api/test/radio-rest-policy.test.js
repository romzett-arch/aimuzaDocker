import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertRadioMutationAccess,
  getRadioReadScope,
  isRadioAdmin,
} from '../src/security/radio-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('radio owner data is scoped at the owner-capable REST tables', () => {
  assert.deepEqual(getRadioReadScope('radio_listens', user, 3), {
    sql: '"user_id" = $3',
    params: ['user-1'],
  });
  assert.deepEqual(getRadioReadScope('radio_predictions', null), { sql: 'FALSE', params: [] });
  assert.deepEqual(getRadioReadScope('radio_config', user), { sql: '', params: [] });
  assert.deepEqual(getRadioReadScope('radio_listens', admin), { sql: '', params: [] });
});

test('direct radio mutations are admin-only', () => {
  for (const table of ['radio_config', 'radio_schedule', 'radio_slots', 'radio_queue_overrides']) {
    assert.throws(() => assertRadioMutationAccess(table, null), error => error.status === 401);
    assert.throws(() => assertRadioMutationAccess(table, user), error => error.status === 403);
    assert.doesNotThrow(() => assertRadioMutationAccess(table, admin));
    assert.doesNotThrow(() => assertRadioMutationAccess(table, service));
  }
  assert.doesNotThrow(() => assertRadioMutationAccess('tracks', user));
});

test('radio admin role aliases are recognized consistently', () => {
  assert.equal(isRadioAdmin(admin), true);
  assert.equal(isRadioAdmin({ ...admin, app_role: 'super_admin' }), true);
  assert.equal(isRadioAdmin(service), true);
  assert.equal(isRadioAdmin(user), false);
});
