export const LOGIN_FAILURE_LIMIT = 3;
export const LOGIN_FAILURE_WINDOW_MS = 15 * 60 * 1000;

export function isPasswordGrantRequest(req) {
  const grantType = req.query?.grant_type || req.body?.grant_type;
  return grantType === 'password';
}

export function getNormalizedLoginEmail(req) {
  const email = req.body?.email;
  return typeof email === 'string' ? email.trim().toLowerCase() : '';
}

export function skipLoginAccountLimiter(req) {
  return !isPasswordGrantRequest(req) || !getNormalizedLoginEmail(req);
}

export function getLoginAccountKey(req) {
  return `login-account:${getNormalizedLoginEmail(req)}`;
}

export function shouldCountLoginFailure(_req, res) {
  return res.statusCode < 400 || res.statusCode >= 500;
}
