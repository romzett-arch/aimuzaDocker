import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertEconomyMutationAccess,
  assertEconomyReadAccess,
  filterEconomyMutationColumns,
  getEconomyMutationScope,
  getEconomyReadScope,
} from '../src/security/economy-rest-policy.js';

const anon = null;
const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };

test('public progression catalogs are readable anonymously', () => {
  for (const table of ['achievements', 'reputation_tiers', 'xp_event_config']) {
    assert.doesNotThrow(() => assertEconomyReadAccess(table, anon));
    assert.deepEqual(getEconomyReadScope(table, anon), { sql: '', params: [] });
  }
});

test('admin economy resources reject ordinary users', () => {
  for (const table of ['economy_config', 'economy_snapshots', 'attribution_pools']) {
    assert.throws(() => assertEconomyReadAccess(table, user), error => error.status === 403);
    assert.doesNotThrow(() => assertEconomyReadAccess(table, admin));
  }
});

test('private economy resources require authentication and scope reads to owner', () => {
  for (const table of ['creator_earnings', 'referral_rewards', 'reputation_events', 'user_achievements']) {
    assert.throws(() => assertEconomyReadAccess(table, anon), error => error.status === 401);
    const scope = getEconomyReadScope(table, user, 4);
    assert.equal(scope.sql, '"user_id" = $4');
    assert.deepEqual(scope.params, ['user-1']);
  }
  assert.deepEqual(getEconomyReadScope('referrals', user, 2), {
    sql: '("referrer_id" = $2 OR "referred_id" = $2)',
    params: ['user-1'],
  });
});

test('referral settings are authenticated-read and admin-write', () => {
  assert.throws(() => assertEconomyReadAccess('referral_settings', anon), error => error.status === 401);
  assert.doesNotThrow(() => assertEconomyReadAccess('referral_settings', user));
  assert.throws(() => assertEconomyMutationAccess('referral_settings', user, 'update'), error => error.status === 403);
  assert.doesNotThrow(() => assertEconomyMutationAccess('referral_settings', admin, 'update'));
});

test('users can only rename their own referral code', () => {
  assert.doesNotThrow(() => assertEconomyMutationAccess('referral_codes', user, 'update'));
  assert.throws(() => assertEconomyMutationAccess('referral_codes', user, 'insert'), error => error.status === 403);
  assert.deepEqual(
    filterEconomyMutationColumns('referral_codes', ['custom_code', 'uses_count', 'user_id'], user, 'update'),
    ['custom_code'],
  );
  assert.deepEqual(getEconomyMutationScope('referral_codes', user, 7), {
    sql: '"user_id" = $7',
    params: ['user-1'],
  });
});
