import test from 'node:test';
import assert from 'node:assert/strict';
import {
  hashRecoveryToken,
  normalizeRecoveryToken,
  recoveryCodeForToken,
  validatePassword,
} from '../src/security/password.js';
import { readSessionVersion } from '../src/security/session-version.js';

test('password policy is identical for signup, account change and recovery', () => {
  assert.equal(validatePassword('Strong!1'), true);
  assert.equal(validatePassword('short!1A'), true);
  assert.equal(validatePassword('weakpass'), false);
  assert.equal(validatePassword('NoSpecial1'), false);
  assert.equal(validatePassword('no-upper!1'), false);
  assert.equal(validatePassword('NoDigit!!'), false);
  assert.equal(validatePassword(null), false);
});

test('recovery tokens accept only canonical 32-byte hex values', () => {
  const token = 'A'.repeat(64);
  assert.equal(normalizeRecoveryToken(` ${token} `), 'a'.repeat(64));
  assert.equal(normalizeRecoveryToken('a'.repeat(63)), null);
  assert.equal(normalizeRecoveryToken('z'.repeat(64)), null);
  assert.equal(normalizeRecoveryToken(undefined), null);
});

test('only a digest of a recovery token is persisted', () => {
  const token = '01'.repeat(32);
  const digest = hashRecoveryToken(token);
  assert.match(digest, /^[a-f0-9]{64}$/);
  assert.notEqual(digest, token);
  assert.equal(recoveryCodeForToken(token), `RESET:${digest}`);
});

test('session versions are normalized before signing or validating JWTs', () => {
  assert.equal(readSessionVersion({ session_version: 3 }), 3);
  assert.equal(readSessionVersion({ raw_user_meta_data: { session_version: '4' } }), 4);
  assert.equal(readSessionVersion({ raw_user_meta_data: {} }), 0);
  assert.equal(readSessionVersion({ session_version: -1 }), 0);
  assert.equal(readSessionVersion({ session_version: 'invalid' }), 0);
});
