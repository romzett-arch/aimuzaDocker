/**
 * Authorization and ownership rules for gallery_items/gallery_likes.
 *
 * The REST layer connects as the database owner, so PostgreSQL RLS is not
 * sufficient here. Every gallery query must be scoped before SQL execution.
 */

import fs from 'fs';
import path from 'path';

const UPLOADS_DIR = path.resolve(process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads');
const GALLERY_TABLES = new Set(['gallery_items', 'gallery_likes']);

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

function isGalleryAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function isGalleryTable(table) {
  return GALLERY_TABLES.has(table);
}

export function getGalleryReadScope(table, user, startIndex = 1) {
  if (!isGalleryTable(table) || isGalleryAdmin(user)) return { sql: '', params: [] };

  const publicItem = `(
    "is_public" IS TRUE
    AND "status" = 'ready'
    AND "moderation_status" = 'approved'
  )`;

  if (table === 'gallery_items') {
    if (!user?.id) return { sql: publicItem, params: [] };
    return {
      sql: `("user_id" = $${startIndex} OR ${publicItem})`,
      params: [user.id],
    };
  }

  if (!user?.id) {
    return {
      sql: `EXISTS (
        SELECT 1 FROM public.gallery_items gallery_item
        WHERE gallery_item.id = "gallery_item_id"
          AND gallery_item.is_public IS TRUE
          AND gallery_item.status = 'ready'
          AND gallery_item.moderation_status = 'approved'
      )`,
      params: [],
    };
  }

  return {
    sql: `("user_id" = $${startIndex} OR EXISTS (
      SELECT 1 FROM public.gallery_items gallery_item
      WHERE gallery_item.id = "gallery_item_id"
        AND (gallery_item.user_id = $${startIndex} OR (
          gallery_item.is_public IS TRUE
          AND gallery_item.status = 'ready'
          AND gallery_item.moderation_status = 'approved'
        ))
    ))`,
    params: [user.id],
  };
}

export function assertGalleryMutationAccess(table, user, operation) {
  if (!isGalleryTable(table)) return;
  requireAuthenticated(user);
  if (isGalleryAdmin(user)) return;
  if (table === 'gallery_likes' && operation === 'update') {
    throw httpError(403, 'Gallery likes cannot be updated', 'GALLERY_LIKE_IMMUTABLE');
  }
}

export function applyGalleryInsertOwnership(table, row, user) {
  if (!isGalleryTable(table) || isGalleryAdmin(user)) return row;

  if (table === 'gallery_likes') {
    return { ...row, user_id: user.id };
  }

  const isPublic = row.is_public === true;
  return {
    ...row,
    user_id: user.id,
    likes_count: 0,
    views_count: 0,
    status: 'ready',
    moderation_status: 'approved',
    published_at: isPublic ? new Date().toISOString() : null,
  };
}

export function applyGalleryUpdateValues(table, updates, user) {
  if (table !== 'gallery_items' || isGalleryAdmin(user)) return updates;
  if (!Object.prototype.hasOwnProperty.call(updates, 'is_public')) return updates;
  return {
    ...updates,
    published_at: updates.is_public === true ? new Date().toISOString() : null,
  };
}

export function filterGalleryMutationColumns(table, columns, user, isInsert = false) {
  if (!isGalleryTable(table) || isGalleryAdmin(user)) return columns;

  if (table === 'gallery_likes') {
    const allowed = new Set(['gallery_item_id', 'user_id']);
    return columns.filter((column) => allowed.has(column));
  }

  const allowed = new Set([
    'id', 'user_id', 'type', 'title', 'description', 'url', 'thumbnail_url',
    'track_id', 'is_public', 'storage_bucket', 'storage_path',
    'thumbnail_storage_path', 'mime_type', 'size_bytes', 'duration_seconds',
    'status', 'moderation_status', 'published_at',
  ]);
  const protectedOnUpdate = new Set([
    'id', 'user_id', 'type', 'url', 'thumbnail_url', 'storage_bucket',
    'storage_path', 'thumbnail_storage_path', 'mime_type', 'size_bytes',
    'duration_seconds', 'status', 'moderation_status',
  ]);

  return columns.filter((column) => allowed.has(column) && (isInsert || !protectedOnUpdate.has(column)));
}

export function getGalleryMutationScope(table, user, startIndex = 1) {
  if (!isGalleryTable(table) || isGalleryAdmin(user)) return { sql: '', params: [] };
  requireAuthenticated(user);
  return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
}

export async function assertGalleryInsertRelation(client, table, row, user) {
  if (!isGalleryTable(table) || isGalleryAdmin(user)) return;

  if (table === 'gallery_likes') {
    const item = await client.query(
      `SELECT 1 FROM public.gallery_items
       WHERE id = $1
         AND (user_id = $2 OR (is_public IS TRUE AND status = 'ready' AND moderation_status = 'approved'))`,
      [row.gallery_item_id, user.id],
    );
    if (item.rowCount !== 1) {
      throw httpError(404, 'Gallery item not found', 'GALLERY_ITEM_NOT_FOUND');
    }
    return;
  }

  if (!['image', 'video'].includes(row.type)) {
    throw httpError(400, 'Unsupported gallery media type', 'INVALID_GALLERY_MEDIA_TYPE');
  }
  if (row.storage_bucket !== 'gallery' || typeof row.storage_path !== 'string') {
    throw httpError(400, 'Owned gallery storage object required', 'GALLERY_STORAGE_REQUIRED');
  }

  const expectedPrefix = `${user.id}/`;
  const storagePath = row.storage_path.replace(/\\/g, '/');
  if (!storagePath.startsWith(expectedPrefix) || storagePath.includes('..')) {
    throw httpError(403, 'Invalid gallery storage path', 'INVALID_GALLERY_STORAGE_PATH');
  }

  const fullPath = path.resolve(UPLOADS_DIR, 'gallery', storagePath);
  if (!fullPath.startsWith(`${path.resolve(UPLOADS_DIR, 'gallery')}${path.sep}`) || !fs.existsSync(fullPath)) {
    throw httpError(400, 'Uploaded gallery file was not found', 'GALLERY_FILE_NOT_FOUND');
  }

  const actualSize = fs.statSync(fullPath).size;
  if (actualSize <= 0 || (row.size_bytes != null && Number(row.size_bytes) !== actualSize)) {
    throw httpError(400, 'Gallery file size does not match upload', 'GALLERY_FILE_SIZE_MISMATCH');
  }

  if (row.track_id) {
    const track = await client.query(
      'SELECT 1 FROM public.tracks WHERE id = $1 AND user_id = $2',
      [row.track_id, user.id],
    );
    if (track.rowCount !== 1) {
      throw httpError(403, 'Track ownership required', 'TRACK_OWNERSHIP_REQUIRED');
    }
  }
}

