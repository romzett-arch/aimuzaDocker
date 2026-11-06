import jwt from 'jsonwebtoken';

const audience = 'studio-audio-reference';

function playableUrl(value) {
  if (typeof value !== 'string' || value.length > 4096 || /localhost|127\.0\.0\.1/i.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password;
  } catch {
    return false;
  }
}

export function issueAudioReference(userId, audioUrl) {
  if (!playableUrl(audioUrl)) return null;
  return jwt.sign({ audioUrl, token_use: audience }, process.env.JWT_SECRET, {
    algorithm: 'HS256', audience, subject: userId, expiresIn: '24h',
  });
}

export function readAudioReference(userId, reference) {
  try {
    const claims = jwt.verify(reference, process.env.JWT_SECRET, {
      algorithms: ['HS256'], audience, subject: userId,
    });
    if (claims.token_use === audience && playableUrl(claims.audioUrl)) return claims.audioUrl;
  } catch {
    // An expired or foreign reference must be rejected before billing.
  }
  return null;
}
