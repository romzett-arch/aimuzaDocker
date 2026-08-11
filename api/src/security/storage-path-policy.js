function isStorageAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function assertOwnedMediaPath(user, bucket, filePath) {
  if (!['tracks', 'covers'].includes(bucket) || isStorageAdmin(user)) return;
  const segments = String(filePath || '').replace(/\\/g, '/').split('/').filter(Boolean);
  if (segments.some((segment) => segment === '.' || segment === '..')) {
    const error = new Error('Storage path must not contain traversal segments');
    error.status = 403;
    error.code = 'STORAGE_PATH_OWNERSHIP_REQUIRED';
    throw error;
  }
  if (bucket === 'tracks' && segments[0] === 'silk-releases') return;
  if (!segments[0] || segments[0] !== user?.id) {
    const error = new Error('Storage path must belong to the authenticated user');
    error.status = 403;
    error.code = 'STORAGE_PATH_OWNERSHIP_REQUIRED';
    throw error;
  }
}
