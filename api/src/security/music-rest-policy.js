/**
 * Authorization policy for tracks and the label release workflow.
 *
 * The custom REST API connects as the database owner, so PostgreSQL RLS is
 * not a security boundary here. Every music-table request must be scoped in
 * this module before SQL is executed.
 */

import fs from 'fs';
import path from 'path';

const UPLOADS_DIR = path.resolve(process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads');

const MUSIC_TABLES = new Set([
  'tracks',
  'addon_services',
  'track_addons',
  'silk_releases',
  'silk_release_assets',
  'silk_release_requests',
  'silk_release_events',
  'silk_release_comments',
  'silk_royalty_statements',
  'silk_royalty_lines',
]);

const SILK_TABLES = new Set([...MUSIC_TABLES].filter((table) => table.startsWith('silk_')));

const USER_TRACK_PROTECTED_COLUMNS = new Set([
  'id', 'user_id', 'created_at', 'moderation_status', 'moderation_reviewed_by',
  'moderation_reviewed_at', 'moderation_notes', 'moderation_rejection_reason',
  'voting_result', 'voting_likes_count', 'voting_dislikes_count', 'voting_started_at',
  'voting_ends_at', 'voting_type', 'distribution_status', 'distribution_submitted_at',
  'distribution_reviewed_at', 'distribution_rejection_reason', 'distribution_platforms',
  'processing_stage', 'processing_progress', 'master_audio_url', 'isrc_code', 'upc_code',
]);

const USER_RELEASE_PROTECTED_COLUMNS = new Set([
  'id', 'user_id', 'status', 'admin_note', 'submitted_at', 'reviewed_at',
  'sent_to_silk_at', 'live_at', 'created_at', 'updated_at',
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

function requireAuthenticated(user) {
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
}

export function isMusicTable(table) {
  return MUSIC_TABLES.has(table);
}

export function isMusicAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function isTrackStaff(user) {
  if (isMusicAdmin(user)) return true;
  return String(user?.app_role || '').toLowerCase() === 'moderator';
}

export function getMusicReadScope(table, user, startIndex = 1) {
  if (!isMusicTable(table)) return { sql: '', params: [] };

  if (table === 'tracks') {
    if (isTrackStaff(user)) return { sql: '', params: [] };
    const activePublicVoting = `(
      "moderation_status" = 'voting'
      AND "voting_type" = 'public'
      AND "voting_result" = 'pending'
      AND "voting_ends_at" > now()
    )`;
    const publicTrack = `(
      "is_public" IS TRUE
      AND "status" = 'completed'
      AND (COALESCE("is_in_my_releases", FALSE) IS FALSE OR ${activePublicVoting})
    )`;
    if (!user?.id) return { sql: publicTrack, params: [] };
    return {
      sql: `("user_id" = $${startIndex} OR ${publicTrack})`,
      params: [user.id],
    };
  }

  if (table === 'addon_services') {
    if (isMusicAdmin(user)) return { sql: '', params: [] };
    return { sql: '"is_active" IS TRUE', params: [] };
  }

  if (table === 'track_addons') {
    if (isMusicAdmin(user)) return { sql: '', params: [] };
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return {
      sql: `EXISTS (
        SELECT 1 FROM public.tracks music_track
        WHERE music_track.id = "track_id" AND music_track.user_id = $${startIndex}
      )`,
      params: [user.id],
    };
  }

  if (isMusicAdmin(user)) return { sql: '', params: [] };
  if (!user?.id) return { sql: 'FALSE', params: [] };

  if (['silk_releases', 'silk_release_assets', 'silk_release_requests', 'silk_royalty_statements'].includes(table)) {
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }
  if (table === 'silk_release_events' || table === 'silk_release_comments') {
    return {
      sql: `EXISTS (
        SELECT 1 FROM public.silk_releases music_release
        WHERE music_release.id = "release_id" AND music_release.user_id = $${startIndex}
      )`,
      params: [user.id],
    };
  }
  if (table === 'silk_royalty_lines') {
    return {
      sql: `EXISTS (
        SELECT 1 FROM public.silk_royalty_statements music_statement
        WHERE music_statement.id = "statement_id" AND music_statement.user_id = $${startIndex}
      )`,
      params: [user.id],
    };
  }
  return { sql: 'FALSE', params: [] };
}

export function assertMusicMutationAccess(table, user, operation, row = {}) {
  if (!isMusicTable(table)) return;
  requireAuthenticated(user);

  if (table === 'tracks') return;
  if (table === 'addon_services') {
    if (!isMusicAdmin(user)) throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
    return;
  }
  if (table === 'track_addons') {
    if (isMusicAdmin(user) || operation === 'insert') return;
    throw httpError(403, 'Track addons are server managed', 'TRACK_ADDON_SERVER_MANAGED');
  }
  if (
    table === 'silk_releases'
    && operation === 'update'
    && Object.prototype.hasOwnProperty.call(row, 'status')
    && user.role !== 'service_role'
  ) {
    throw httpError(403, 'Release status can only be changed through RPC', 'SILK_RPC_REQUIRED');
  }
  if (table === 'silk_release_requests' && user.role !== 'service_role') {
    throw httpError(403, 'Release requests can only be changed through RPC', 'SILK_RPC_REQUIRED');
  }
  if (isMusicAdmin(user)) return;

  if (table === 'silk_releases') {
    return;
  }
  if (table === 'silk_release_assets') return;
  if (table === 'silk_release_events' && operation === 'insert') {
    if (!['created', 'asset_uploaded'].includes(row?.event_type)) {
      throw httpError(403, 'Invalid user release event', 'INVALID_RELEASE_EVENT');
    }
    return;
  }
  if (table === 'silk_release_comments' && operation === 'insert') return;

  throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
}

export function applyMusicInsertOwnership(table, row, user) {
  if (!isMusicTable(table) || isMusicAdmin(user)) return row;
  if (table === 'silk_release_assets') {
    return {
      ...row,
      user_id: user.id,
      storage_bucket: 'tracks',
      public_url: null,
      validation_status: 'valid',
      validation_notes: null,
    };
  }
  if (table === 'track_addons') {
    return { ...row, user_id: user.id, status: 'pending', result_url: null };
  }
  if (table === 'tracks' || table === 'silk_releases' || table === 'silk_release_requests') {
    return { ...row, user_id: user.id };
  }
  if (table === 'silk_release_events') {
    return { ...row, actor_id: user.id, from_status: null, to_status: null };
  }
  if (table === 'silk_release_comments') return { ...row, author_id: user.id, is_admin_note: false };
  return row;
}

export function filterMusicMutationColumns(table, columns, user, isInsert = false) {
  if (!isMusicTable(table) || isMusicAdmin(user)) return columns;
  if (table === 'tracks') {
    const protectedColumns = isInsert
      ? new Set([...USER_TRACK_PROTECTED_COLUMNS].filter((column) => column !== 'user_id'))
      : USER_TRACK_PROTECTED_COLUMNS;
    return columns.filter((column) => !protectedColumns.has(column));
  }
  if (table === 'track_addons') {
    const allowed = new Set(['track_id', 'user_id', 'addon_service_id', 'status', 'result_url']);
    return columns.filter((column) => allowed.has(column));
  }
  if (table === 'silk_releases') {
    const protectedColumns = isInsert
      ? new Set([...USER_RELEASE_PROTECTED_COLUMNS].filter((column) => !['user_id'].includes(column)))
      : USER_RELEASE_PROTECTED_COLUMNS;
    return columns.filter((column) => !protectedColumns.has(column));
  }
  if (table === 'silk_release_assets') {
    const protectedColumns = new Set(['id', 'created_at', 'updated_at']);
    if (!isInsert) {
      protectedColumns.add('user_id');
      protectedColumns.add('validation_status');
      protectedColumns.add('validation_notes');
    }
    return columns.filter((column) => !protectedColumns.has(column));
  }
  if (table === 'silk_release_requests') {
    const allowed = new Set(['release_id', 'user_id', 'request_type', 'message', 'status']);
    return columns.filter((column) => allowed.has(column));
  }
  if (table === 'silk_release_events') {
    const allowed = new Set(['release_id', 'actor_id', 'event_type', 'payload']);
    return columns.filter((column) => allowed.has(column));
  }
  if (table === 'silk_release_comments') {
    const allowed = new Set(['release_id', 'author_id', 'is_admin_note', 'body']);
    return columns.filter((column) => allowed.has(column));
  }
  return [];
}

export function getMusicMutationScope(table, user, startIndex = 1, operation = 'update') {
  if (!isMusicTable(table)) return { sql: '', params: [] };
  requireAuthenticated(user);

  if (table === 'tracks') {
    if (isTrackStaff(user)) return { sql: '', params: [] };
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }
  if (table === 'track_addons') {
    if (isMusicAdmin(user)) return { sql: '', params: [] };
    return {
      sql: `EXISTS (
        SELECT 1 FROM public.tracks music_track
        WHERE music_track.id = "track_id" AND music_track.user_id = $${startIndex}
      )`,
      params: [user.id],
    };
  }
  if (isMusicAdmin(user)) {
    if (table === 'silk_releases' && operation === 'delete') {
      return { sql: `"status" IN ('draft', 'rejected', 'archived')`, params: [] };
    }
    return { sql: '', params: [] };
  }
  if (table === 'silk_releases') {
    return {
      sql: `"user_id" = $${startIndex} AND "status" IN ('draft', 'ready', 'needs_changes', 'rejected')`,
      params: [user.id],
    };
  }
  if (table === 'silk_release_assets') {
    return {
      sql: `"user_id" = $${startIndex} AND EXISTS (
        SELECT 1 FROM public.silk_releases music_release
        WHERE music_release.id = "release_id"
          AND music_release.user_id = $${startIndex}
          AND music_release.status IN ('draft', 'ready', 'needs_changes', 'rejected')
      )`,
      params: [user.id],
    };
  }
  return { sql: 'FALSE', params: [] };
}

export async function assertMusicInsertRelation(client, table, row, user) {
  if (isMusicAdmin(user)) return;

  if (table === 'track_addons') {
    const relation = await client.query(
      `SELECT 1
       FROM public.tracks track
       JOIN public.addon_services service ON service.id = $2
       WHERE track.id = $1 AND track.user_id = $3
         AND service.is_active IS TRUE AND service.name <> 'short_video'`,
      [row.track_id, row.addon_service_id, user.id],
    );
    if (relation.rowCount !== 1) {
      throw httpError(403, 'Track ownership and an active addon service are required', 'TRACK_ADDON_RELATION_REQUIRED');
    }
    return;
  }

  if (!SILK_TABLES.has(table)) return;

  if (table === 'silk_releases') {
    if (row.status && !['draft', 'ready'].includes(row.status)) {
      throw httpError(403, 'Invalid initial release status', 'INVALID_RELEASE_STATUS');
    }
    if (row.source_track_id) {
      const track = await client.query(
        'SELECT 1 FROM public.tracks WHERE id = $1 AND user_id = $2',
        [row.source_track_id, user.id],
      );
      if (track.rowCount !== 1) throw httpError(403, 'Track ownership required', 'TRACK_OWNERSHIP_REQUIRED');
    }
    return;
  }

  if (['silk_release_assets', 'silk_release_requests', 'silk_release_events', 'silk_release_comments'].includes(table)) {
    const release = await client.query(
      `SELECT status FROM public.silk_releases WHERE id = $1 AND user_id = $2`,
      [row.release_id, user.id],
    );
    if (release.rowCount !== 1) throw httpError(403, 'Release ownership required', 'RELEASE_OWNERSHIP_REQUIRED');
    if (table === 'silk_release_assets' && !['draft', 'ready', 'needs_changes', 'rejected'].includes(release.rows[0].status)) {
      throw httpError(409, 'Release files are locked', 'RELEASE_LOCKED');
    }
    if (table === 'silk_release_assets') {
      const expectedPrefix = `silk-releases/${user.id}/${row.release_id}/`;
      const storagePath = String(row.storage_path || '').replace(/\\/g, '/');
      if (row.storage_bucket !== 'tracks' || !storagePath.startsWith(expectedPrefix)) {
        throw httpError(403, 'Invalid release asset path', 'INVALID_ASSET_PATH');
      }

      const allowedExtensions = {
        master_wav: new Set(['.wav']),
        reference_mp3: new Set(['.mp3']),
        cover_art: new Set(['.jpg', '.jpeg', '.png', '.webp']),
        package_zip: new Set(['.zip']),
      };
      const extension = path.extname(storagePath).toLowerCase();
      const allowed = allowedExtensions[row.asset_type];
      if (allowed && !allowed.has(extension)) {
        throw httpError(400, 'Invalid file type for release asset', 'INVALID_ASSET_TYPE');
      }

      const fullPath = path.resolve(UPLOADS_DIR, 'tracks', storagePath);
      if (!fullPath.startsWith(`${UPLOADS_DIR}${path.sep}`) || !fs.existsSync(fullPath)) {
        throw httpError(400, 'Uploaded release file was not found', 'ASSET_FILE_NOT_FOUND');
      }
      const actualSize = fs.statSync(fullPath).size;
      if (actualSize <= 0 || Number(row.file_size) !== actualSize) {
        throw httpError(400, 'Release file size does not match upload', 'ASSET_SIZE_MISMATCH');
      }
    }
    if (table === 'silk_release_requests' && row.status && row.status !== 'open') {
      throw httpError(403, 'Invalid request status', 'INVALID_REQUEST_STATUS');
    }
  }
}
