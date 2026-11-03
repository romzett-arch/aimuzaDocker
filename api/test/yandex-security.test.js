import test from 'node:test';
import assert from 'node:assert/strict';
import { authorizeUrl, configuration, providerProfile, secret, finishUrl } from '../src/security/yandex.js';

const config = configuration({});
test('Yandex requests only account/email with S256 PKCE and fixed redirect', () => {
  const verifier = secret(), state = secret();
  const url = new URL(authorizeUrl(config, state, verifier));
  assert.equal(url.origin, 'https://oauth.yandex.ru');
  assert.equal(url.searchParams.get('scope'), 'login:email login:info');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://aimuza.ru/auth/v1/yandex/callback');
  assert.equal(url.href.includes(verifier), false);
  assert.equal(url.searchParams.get('state'), state);
});
test('PKCE code exchange needs no client secret and profile token stays in header', async () => {
  const verifier = secret(), state = secret();
  const calls = [];
  const profile = await providerProfile(config, { verifier }, { state, code: 'fixture' }, async (url, options) => {
    calls.push({ url, options });
    return { ok: true, json: async () => calls.length === 1 ? { access_token: 'secret-token' } : { id: '123', client_id: config.clientId, default_email: 'OWNER@EXAMPLE.COM', display_name: 'Owner', birthday: 'hidden', sex: 'hidden' } };
  });
  assert.deepEqual(profile, { subject: '123', email: 'owner@example.com', name: 'Owner' });
  assert.equal(calls[0].options.body.get('code_verifier'), verifier);
  assert.equal(calls[0].options.body.has('client_secret'), false);
  assert.equal(calls[1].options.headers.Authorization, 'OAuth secret-token');
  assert.equal(calls[1].url.includes('secret-token'), false);
  assert.ok(calls.every(c => c.options.redirect === 'error'));
});
test('wrong-client and absent-subject responses never create an identity', async () => {
  for (const user of [{ id: '7', client_id: 'other' }, { client_id: config.clientId }]) {
    await assert.rejects(providerProfile(config, { verifier: secret() }, { state: secret(), code: 'fixture' }, async url => ({ ok: true, json: async () => url.endsWith('/token') ? { access_token: 'token' } : user })), /YANDEX_INVALID_PROVIDER/);
  }
});
test('provider failures and malformed callback fail closed', async () => {
  await assert.rejects(providerProfile(config, {}, { state: 'invalid' }, () => { throw Error('must not call'); }), /YANDEX_INVALID_CALLBACK/);
  await assert.rejects(providerProfile(config, { verifier: secret() }, { state: secret(), code: 'fixture' }, async () => ({ ok: false, json: async () => ({ error: 'invalid_grant' }) })), /YANDEX_PROVIDER_ERROR/);
});
test('return URLs and client id cannot be replaced by request parameters', () => {
  assert.equal(finishUrl(config, 'android', 'test'), 'aimuza://yandex?ticket=test');
  assert.equal(finishUrl(config, 'studio', 'test'), 'https://app.aimuza.ru/api/auth/yandex/finish?ticket=test');
  assert.throws(() => configuration({ YANDEX_REDIRECT_URI: 'https://evil.example/callback' }));
  assert.throws(() => configuration({ YANDEX_CLIENT_ID: '../anything' }));
});
