import { assertOwnedMediaPath } from './storage-path-policy.js';

// Generated archives are server-managed. Signing them does not grant write access.
export async function assertMediaSigningAccess(user, bucket, filePath, client) {
  if (user?.role === 'service_role') return;
  if (bucket !== 'tracks' || !/^release-packages\/[0-9a-f-]{36}\/release-package-audio-v3\.zip$/i.test(filePath)) {
    return assertOwnedMediaPath(user, bucket, filePath);
  }
  const isAdmin = ['admin', 'super_admin', 'superadmin'].includes(user?.app_role);
  const result = await client.query(
    `SELECT 1 FROM public.silk_release_assets asset
     JOIN public.silk_releases release ON release.id = asset.release_id
     WHERE asset.storage_bucket = $1 AND asset.storage_path = $2
       AND asset.asset_type = 'package_zip'
       AND ($3::boolean OR release.user_id = $4::uuid)
     LIMIT 1`,
    [bucket, filePath, isAdmin, user?.id || null],
  );
  if (!user?.id || result.rowCount !== 1) {
    throw Object.assign(new Error('Release package access denied'), {
      status: 403, code: 'STORAGE_PATH_OWNERSHIP_REQUIRED',
    });
  }
}
