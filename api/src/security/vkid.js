import { createHash, randomBytes } from 'node:crypto';

export const digest = value => createHash('sha256').update(value).digest('hex');
export const secret = () => randomBytes(32).toString('base64url');
export const validSecret = value => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
export const fail = code => { throw Object.assign(new Error(code), { code }); };

export function configuration(env = process.env) {
  const site = env.VKID_SITE_ORIGIN || 'https://aimuza.ru';
  const studio = env.VKID_STUDIO_ORIGIN || 'https://app.aimuza.ru';
  const redirect = env.VKID_REDIRECT_URI || 'https://aimuza.ru/auth/v1/vkid/callback';
  for (const raw of [site, studio, redirect]) {
    const u = new URL(raw);
    if (u.username || u.password || u.search || u.hash || (u.protocol !== 'https:' && !(u.protocol === 'http:' && u.hostname === 'localhost'))) fail('VKID_CONFIGURATION');
  }
  if (new URL(redirect).origin !== new URL(site).origin) fail('VKID_CONFIGURATION');
  return { site, studio, redirect, clientId: env.VKID_WEB_CLIENT_ID || '54873671', enabled: env.VKID_ENABLED === 'true' };
}

export function authorizeUrl(config, state, verifier) {
  const params = new URLSearchParams({ client_id: config.clientId, redirect_uri: config.redirect,
    response_type: 'code', state, code_challenge: createHash('sha256').update(verifier).digest('base64url'),
    code_challenge_method: 'S256', scope: 'email' });
  return 'https://id.vk.ru/authorize?' + params;
}

export async function providerProfile(config, flow, query, fetcher = fetch) {
  if (!validSecret(query.state) || typeof query.code !== 'string' || !query.code || query.code.length > 2048 || typeof query.device_id !== 'string' || !query.device_id || query.device_id.length > 1024) fail('VKID_INVALID_CALLBACK');
  const post = async (path, body) => {
    const response = await fetcher('https://id.vk.ru/oauth2/' + path, {
      method: 'POST', body: new URLSearchParams({ client_id: config.clientId, ...body }),
      redirect: 'error', signal: AbortSignal.timeout(15000),
    });
    const data = await response.json();
    if (!response.ok || data.error) fail('VKID_PROVIDER_ERROR');
    return data;
  };
  const token = await post('auth', { grant_type: 'authorization_code', code: query.code,
    code_verifier: flow.verifier, redirect_uri: config.redirect, device_id: query.device_id, state: query.state });
  if (token.state !== query.state || !token.access_token || !/^\d+$/.test(String(token.user_id))) fail('VKID_INVALID_PROVIDER');
  const { user } = await post('user_info', { access_token: token.access_token });
  if (!user || String(user.user_id) !== String(token.user_id)) fail('VKID_INVALID_PROVIDER');
  return { subject: String(user.user_id), email: typeof user.email === 'string' ? user.email.toLowerCase().trim() : '',
    name: [user.first_name, user.last_name].filter(v => typeof v === 'string').join(' ').slice(0, 80) };
}

export function finishUrl(config, destination, ticket) {
  if (destination === 'android') return 'aimuza://vkid?ticket=' + ticket;
  if (destination === 'studio') return config.studio + '/api/auth/vkid/finish?ticket=' + ticket;
  return config.site + '/auth?vkid=finish#ticket=' + ticket;
}
