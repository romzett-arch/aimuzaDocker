function isStorageAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function assertOwnedMediaPath(user, bucket, filePath) {
  if (user?.role === 'service_role') return;
  if (bucket==='ad-creatives' && isStorageAdmin(user)) return;
  const userBuckets = new Set(['tracks','covers','avatars','forum-files','gallery']);
  if (!userBuckets.has(bucket)) {
    const error = new Error('Bucket is server-managed');
    error.status = 403;
    error.code = 'STORAGE_SERVER_ONLY';
    throw error;
  }
  const segments = String(filePath || '').replace(/\\/g, '/').split('/').filter(Boolean);
  if(bucket==='gallery' && segments.length<3) throw Object.assign(new Error('Gallery asset path is required'),{status:403,code:'STORAGE_PATH_OWNERSHIP_REQUIRED'});
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
