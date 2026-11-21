export function maxIdentity(user, timestamp) {
  const name = [user.first_name, user.last_name]
    .filter(part => typeof part === 'string')
    .join(' ')
    .replace(/[\p{Cc}\u202a-\u202e\u2066-\u2069]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 160);
  return {
    name: name || undefined,
    observedAt: Number.isSafeInteger(timestamp) && timestamp > 0 ? timestamp : Date.now(),
  };
}
