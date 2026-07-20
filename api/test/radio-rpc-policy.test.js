import test from 'node:test';
import assert from 'node:assert/strict';
import { assertRadioRpcAccess } from '../src/security/radio-rpc-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };

test('radio administration RPCs require an administrator', () => {
  for (const fnName of [
    'admin_set_radio_queue_override',
    'admin_update_radio_config',
    'get_l2e_admin_stats',
    'radio_create_next_slot',
    'radio_resolve_predictions',
  ]) {
    assert.throws(() => assertRadioRpcAccess(fnName, null), error => error.status === 401);
    assert.throws(() => assertRadioRpcAccess(fnName, user), error => error.status === 403);
    assert.doesNotThrow(() => assertRadioRpcAccess(fnName, admin));
  }
});

test('public radio RPCs remain available to their normal callers', () => {
  for (const fnName of ['get_radio_stats', 'radio_heartbeat', 'radio_place_bid']) {
    assert.doesNotThrow(() => assertRadioRpcAccess(fnName, user));
  }
});
