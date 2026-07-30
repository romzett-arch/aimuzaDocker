import test from 'node:test';
import assert from 'node:assert/strict';
import {
  LOGIN_FAILURE_LIMIT,
  LOGIN_FAILURE_WINDOW_MS,
  getLoginAccountKey,
  isPasswordGrantRequest,
  shouldCountLoginFailure,
  skipLoginAccountLimiter,
} from '../src/security/login-rate-limit.js';

test('password login limiter is three failed attempts per fifteen minutes', () => {
  assert.equal(LOGIN_FAILURE_LIMIT, 3);
  assert.equal(LOGIN_FAILURE_WINDOW_MS, 15 * 60 * 1000);
});

test('login account key normalizes email and ignores refresh grants', () => {
  const passwordRequest = {
    query: { grant_type: 'password' },
    body: { email: ' Admin@Example.COM ' },
  };
  const refreshRequest = {
    query: { grant_type: 'refresh_token' },
    body: {},
  };

  assert.equal(isPasswordGrantRequest(passwordRequest), true);
  assert.equal(getLoginAccountKey(passwordRequest), 'login-account:admin@example.com');
  assert.equal(skipLoginAccountLimiter(passwordRequest), false);
  assert.equal(skipLoginAccountLimiter(refreshRequest), true);
});

test('only client-side login failures consume the limiter', () => {
  assert.equal(shouldCountLoginFailure(null, { statusCode: 200 }), true);
  assert.equal(shouldCountLoginFailure(null, { statusCode: 400 }), false);
  assert.equal(shouldCountLoginFailure(null, { statusCode: 401 }), false);
  assert.equal(shouldCountLoginFailure(null, { statusCode: 500 }), true);
});
