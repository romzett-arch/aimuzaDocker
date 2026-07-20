import test from 'node:test';
import assert from 'node:assert/strict';
import { assertAdsRpcAccess } from '../src/security/ads-rpc-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('public delivery RPCs do not expose arbitrary identities', () => {
  for (const fn of [
    'get_public_ad_settings', 'request_ad_for_slot', 'record_ad_impression_v2',
    'record_ad_click_v2', 'record_ad_view_duration_v2', 'radio_record_ad_event',
  ]) {
    assert.doesNotThrow(() => assertAdsRpcAccess(fn, null, {}));
  }
});

test('legacy client-controlled advertising RPCs are disabled', () => {
  for (const fn of ['get_ad_for_slot', 'record_ad_impression', 'record_ad_click', 'radio_skip_ad']) {
    assert.throws(() => assertAdsRpcAccess(fn, user, {}), error => error.code === 'LEGACY_RPC_DISABLED');
    assert.doesNotThrow(() => assertAdsRpcAccess(fn, service, {}));
  }
});

test('ad-free purchases bind identity to caller', () => {
  const params = { p_user_id: 'victim' };
  assertAdsRpcAccess('purchase_ad_free', user, params);
  assert.equal(params.p_user_id, 'user-1');
  assert.throws(() => assertAdsRpcAccess('purchase_ad_free', null, {}), error => error.status === 401);
});

test('campaign administration RPCs are admin-only', () => {
  for (const fn of ['admin_set_ad_campaign_slots', 'admin_set_ad_campaign_status', 'get_ad_campaign_readiness']) {
    assert.throws(() => assertAdsRpcAccess(fn, user, {}), error => error.status === 403);
    assert.doesNotThrow(() => assertAdsRpcAccess(fn, admin, {}));
  }
});
