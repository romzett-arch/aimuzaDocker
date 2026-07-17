export function readSessionVersion(source) {
  const raw = source?.session_version ?? source?.raw_user_meta_data?.session_version ?? 0;
  const version = Number(raw);
  return Number.isSafeInteger(version) && version >= 0 ? version : 0;
}
