import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertAdsMutationAccess,
  assertAdsReadAccess,
  isAdsTable,
} from '../src/security/ads-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const service = { id: 'service-role', role: 'service_role' };

test('advertising tables form an explicit protected domain', () => {
  for (const table of [
    'ad_campaigns', 'ad_creatives', 'ad_deliveries', 'ad_impressions',
    'ad_settings', 'ad_slots', 'ad_targeting', 'radio_ad_events',
    'radio_ad_breaks', 'radio_ad_placements',
  ]) {
    assert.equal(isAdsTable(table), true);
  }
  assert.equal(isAdsTable('tracks'), false);
});

test('advertising tables reject anonymous and ordinary-user reads', () => {
  for (const table of ['ad_campaigns', 'ad_impressions', 'ad_settings', 'radio_ad_placements']) {
    assert.throws(() => assertAdsReadAccess(table, null), error => error.status === 401);
    assert.throws(() => assertAdsReadAccess(table, user), error => error.status === 403);
    assert.doesNotThrow(() => assertAdsReadAccess(table, admin));
    assert.doesNotThrow(() => assertAdsReadAccess(table, service));
  }
});

test('advertising mutations are admin-only', () => {
  for (const table of ['ad_campaigns', 'ad_settings', 'ad_slots', 'radio_ad_placements']) {
    assert.throws(() => assertAdsMutationAccess(table, null), error => error.status === 401);
    assert.throws(() => assertAdsMutationAccess(table, user), error => error.status === 403);
    assert.doesNotThrow(() => assertAdsMutationAccess(table, admin));
  }
});

test('campaign status updates must pass the readiness RPC', () => {
  assert.throws(
    () => assertAdsMutationAccess('ad_campaigns', admin, 'update', { status: 'active' }),
    error => error.code === 'AD_STATUS_RPC_REQUIRED',
  );
  assert.doesNotThrow(() => assertAdsMutationAccess('ad_campaigns', admin, 'update', { name: 'Новая реклама' }));
  assert.doesNotThrow(() => assertAdsMutationAccess('ad_campaigns', admin, 'insert', { status: 'draft' }));
});
