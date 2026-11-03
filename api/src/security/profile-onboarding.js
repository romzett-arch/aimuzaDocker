// Existing social accounts keep a manually edited nickname. Only our generated
// placeholder, or an explicit unfinished-registration marker, needs onboarding.
export function needsNickname(metadata = {}, username = '') {
  if (metadata.nickname_selected_at) return false;
  if (metadata.nickname_required === true) return true;
  const prefix = { vkid: 'vk_', yandex: 'ya_' }[metadata.provider];
  return Boolean(prefix && username === metadata.username &&
    new RegExp('^' + prefix + '[A-Za-z0-9_-]{24}$').test(username));
}

export function normalizeNickname(value) {
  if (typeof value !== 'string') return null;
  const name = value.normalize('NFC').trim().replace(/ +/g, ' ');
  if (name.length < 3 || name.length > 30 || !/^[\p{L}\p{N}][\p{L}\p{N} _.\-]*$/u.test(name)) return null;
  // Do not let the old technical value become a confirmed public nickname.
  if (/^(?:ya|vk)_[A-Za-z0-9_-]{24,32}$/.test(name)) return null;
  return name;
}
