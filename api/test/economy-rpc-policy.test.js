import test from 'node:test';
import assert from 'node:assert/strict';
import { assertEconomyRpcAccess } from '../src/security/economy-rpc-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('money and admin XP functions are admin-only and never anonymous', () => {
  for (const fn of ['add_user_credits', 'admin_add_xp', 'admin_grant_user_income', 'deduct_user_xp', 'fn_add_xp']) {
    assert.throws(() => assertEconomyRpcAccess(fn, null, {}), error => error.status === 401);
    assert.throws(() => assertEconomyRpcAccess(fn, user, {}), error => error.status === 403);
    assert.doesNotThrow(() => assertEconomyRpcAccess(fn, admin, {}));
  }
});

test('internal credit and XP transaction boundaries require service role', () => {
  for (const fn of ['award_xp', 'safe_award_xp', 'process_payment_completion', 'refund_generation_failed']) {
    assert.throws(() => assertEconomyRpcAccess(fn, user, {}), error => error.code === 'SERVICE_ROLE_REQUIRED');
    assert.throws(() => assertEconomyRpcAccess(fn, admin, {}), error => error.code === 'SERVICE_ROLE_REQUIRED');
    assert.doesNotThrow(() => assertEconomyRpcAccess(fn, service, {}));
  }
});

test('self-service RPC identities are bound to authenticated caller', () => {
  for (const fn of ['check_user_achievements', 'debit_balance', 'debit_for_generation', 'get_creator_earnings_profile', 'get_or_create_referral_code', 'radio_award_listen_xp']) {
    const params = { p_user_id: 'victim', user_uuid: 'victim' };
    assertEconomyRpcAccess(fn, user, params);
    assert.equal(params.p_user_id, 'user-1');
    assert.equal('user_uuid' in params, false);
  }
});

test('referral registration is bound to the authenticated referee', () => {
  const params = { p_referee_id: 'victim' };
  assertEconomyRpcAccess('register_referral', user, params);
  assert.equal(params.p_referee_id, 'user-1');
});

test('referral settings update and economy health require admin', () => {
  for (const fn of ['update_referral_settings', 'get_referral_overview', 'get_economy_health', 'process_payment_refund']) {
    assert.throws(() => assertEconomyRpcAccess(fn, user, {}), error => error.status === 403);
    assert.doesNotThrow(() => assertEconomyRpcAccess(fn, admin, {}));
  }
});
