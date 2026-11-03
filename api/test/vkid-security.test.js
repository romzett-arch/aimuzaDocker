import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { configuration, authorizeUrl, providerProfile, secret, digest, finishUrl } from '../src/security/vkid.js';

const config = configuration({});
test('PKCE verifier stays on server, redirect and state are exact', () => {
  const state = secret(), verifier = secret();
  const url = new URL(authorizeUrl(config, state, verifier));
  assert.equal(url.origin, 'https://id.vk.ru');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://aimuza.ru/auth/v1/vkid/callback');
  assert.equal(url.searchParams.get('state'), state);
  assert.equal(url.searchParams.get('code_challenge'), createHash('sha256').update(verifier).digest('base64url'));
  assert.equal(url.href.includes(verifier), false);
  assert.notEqual(digest(state), state);
});
test('return destinations never accept arbitrary redirect URLs', () => {
  assert.equal(finishUrl(config, 'studio', 'test'), 'https://app.aimuza.ru/api/auth/vkid/finish?ticket=test');
  assert.equal(finishUrl(config, 'android', 'test'), 'aimuza://vkid?ticket=test');
  assert.throws(() => configuration({ VKID_REDIRECT_URI: 'https://evil.example/callback' }));
  assert.throws(() => configuration({ VKID_SITE_ORIGIN: 'http://aimuza.ru' }));
});
test('provider code is exchanged with PKCE and verified against user_info', async () => {
  const state = secret(), verifier = secret();
  const requests = [];
  const profile = await providerProfile(config, { verifier }, { state, code: 'code', device_id: 'device' }, async (url, options) => {
    requests.push({ url, options });
    return { ok: true, json: async () => requests.length === 1 ? { access_token: 'provider-secret', state, user_id: 7 } : { user: { user_id: '7', email: 'OWNER@EXAMPLE.COM', first_name: 'Owner' } } };
  });
  assert.deepEqual(profile, { subject: '7', email: 'owner@example.com', name: 'Owner' });
  assert.equal(requests[0].options.body.get('code_verifier'), verifier);
  assert.equal(requests[0].options.body.get('device_id'), 'device');
  assert.equal(requests.every(r => r.options.redirect === 'error'), true);
  assert.equal(JSON.stringify(profile).includes('provider-secret'), false);
});
test('provider state and subject substitutions fail closed', async () => {
  const state = secret();
  for (const mismatch of ['state', 'subject']) {
    await assert.rejects(providerProfile(config, { verifier: secret() }, { state, code: 'code', device_id: 'device' }, async url => ({ ok: true, json: async () => url.endsWith('/auth') ? { access_token: 'token', state: mismatch === 'state' ? secret() : state, user_id: 7 } : { user: { user_id: 8 } } })), /VKID_INVALID_PROVIDER/);
  }
});
test('cancelled or malformed callbacks never call the provider', async () => {
  await assert.rejects(providerProfile(config, {}, { state: 'bad' }, () => { throw Error('must not call'); }), /VKID_INVALID_CALLBACK/);
});
