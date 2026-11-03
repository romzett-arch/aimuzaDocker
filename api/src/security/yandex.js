import { createHash } from 'node:crypto';
export { digest, secret, validSecret, fail } from './vkid.js';
import { validSecret, fail, configuration as baseConfiguration } from './vkid.js';

export function configuration(env = process.env) {
  const base = baseConfiguration({ VKID_SITE_ORIGIN: env.YANDEX_SITE_ORIGIN,
    VKID_STUDIO_ORIGIN: env.YANDEX_STUDIO_ORIGIN,
    VKID_REDIRECT_URI: env.YANDEX_REDIRECT_URI || 'https://aimuza.ru/auth/v1/yandex/callback' });
  const clientId = env.YANDEX_CLIENT_ID || 'e0e64eae06f84e5dabb798f9e757f648';
  if (!/^[a-f0-9]{32}$/.test(clientId)) fail('YANDEX_CONFIGURATION');
  return { ...base, clientId, enabled: env.YANDEX_ENABLED === 'true' };
}
export function authorizeUrl(config, state, verifier) {
  return 'https://oauth.yandex.ru/authorize?' + new URLSearchParams({ response_type: 'code', client_id: config.clientId,
    redirect_uri: config.redirect, state, scope: 'login:email login:info', code_challenge_method: 'S256',
    code_challenge: createHash('sha256').update(verifier).digest('base64url') });
}
export async function providerProfile(config, flow, query, fetcher = fetch) {
  if (!validSecret(query.state) || typeof query.code !== 'string' || !query.code || query.code.length > 2048) fail('YANDEX_INVALID_CALLBACK');
  const tokenResponse = await fetcher('https://oauth.yandex.ru/token', { method: 'POST',
    body: new URLSearchParams({ grant_type: 'authorization_code', client_id: config.clientId, code: query.code,
      code_verifier: flow.verifier }), redirect: 'error', signal: AbortSignal.timeout(15000) });
  const token = await tokenResponse.json();
  if (!tokenResponse.ok || token.error || typeof token.access_token !== 'string' || !token.access_token) fail('YANDEX_PROVIDER_ERROR');
  const response = await fetcher('https://login.yandex.ru/info?format=json', {
    headers: { Authorization: 'OAuth ' + token.access_token }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  const user = await response.json();
  if (!response.ok || user.error || !/^\d+$/.test(String(user.id)) || user.client_id !== config.clientId) fail('YANDEX_INVALID_PROVIDER');
  return { subject: String(user.id), email: typeof user.default_email === 'string' ? user.default_email.trim().toLowerCase() : '',
    name: String(user.display_name || user.real_name || user.login || 'Пользователь').slice(0, 80) };
}
export function finishUrl(config, destination, ticket) {
  if (destination === 'android') return 'aimuza://yandex?ticket=' + ticket;
  if (destination === 'studio') return config.studio + '/api/auth/yandex/finish?ticket=' + ticket;
  return config.site + '/auth?yandex=finish#ticket=' + ticket;
}
