const STORAGE_OBJECT_PREFIX = '/storage/v1/object/';
const NON_UPLOAD_POST_PREFIXES = ['sign/', 'public-url/'];

/**
 * Only binary object writes consume the upload quota.
 * Supabase-compatible signed/public URL helpers are POST requests too, but they
 * do not upload data and must not exhaust the quota while preparing a release.
 */
export function isStorageObjectUpload(method, originalUrl = '') {
  const normalizedMethod = String(method).toUpperCase();
  if (normalizedMethod !== 'POST' && normalizedMethod !== 'PUT') return false;

  const pathname = String(originalUrl).split('?')[0];
  if (!pathname.startsWith(STORAGE_OBJECT_PREFIX)) return false;

  const objectPath = pathname.slice(STORAGE_OBJECT_PREFIX.length);
  if (!objectPath.includes('/')) return false;

  if (
    normalizedMethod === 'POST'
    && NON_UPLOAD_POST_PREFIXES.some((prefix) => objectPath.startsWith(prefix))
  ) {
    return false;
  }

  return true;
}
