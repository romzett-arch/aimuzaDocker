import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyGalleryInsertOwnership,
  applyGalleryUpdateValues,
  assertGalleryMutationAccess,
  filterGalleryMutationColumns,
  getGalleryMutationScope,
  getGalleryReadScope,
} from '../src/security/gallery-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };

test('anonymous gallery reads are limited to approved public ready items', () => {
  const scope = getGalleryReadScope('gallery_items', null);
  assert.match(scope.sql, /is_public/);
  assert.match(scope.sql, /status.*ready/s);
  assert.match(scope.sql, /moderation_status.*approved/s);
  assert.deepEqual(scope.params, []);
});

test('authenticated gallery reads include only own and public items', () => {
  const scope = getGalleryReadScope('gallery_items', user, 4);
  assert.match(scope.sql, /user_id.*\$4/s);
  assert.match(scope.sql, /is_public/s);
  assert.deepEqual(scope.params, ['user-1']);
  assert.equal(getGalleryReadScope('gallery_items', admin).sql, '');
});

test('gallery mutations require authentication and are owner scoped', () => {
  assert.throws(() => assertGalleryMutationAccess('gallery_items', null, 'delete'), /Authentication/);
  assert.doesNotThrow(() => assertGalleryMutationAccess('gallery_items', user, 'delete'));
  assert.deepEqual(getGalleryMutationScope('gallery_items', user, 7), {
    sql: '"user_id" = $7',
    params: ['user-1'],
  });
});

test('gallery inserts force ownership and server managed lifecycle fields', () => {
  const row = applyGalleryInsertOwnership('gallery_items', {
    user_id: 'victim',
    is_public: true,
    likes_count: 999,
    status: 'failed',
  }, user);
  assert.equal(row.user_id, 'user-1');
  assert.equal(row.likes_count, 0);
  assert.equal(row.views_count, 0);
  assert.equal(row.status, 'ready');
  assert.equal(row.moderation_status, 'approved');
  assert.ok(row.published_at);
});

test('ordinary users cannot rewrite storage and moderation metadata', () => {
  assert.deepEqual(
    filterGalleryMutationColumns(
      'gallery_items',
      ['title', 'is_public', 'user_id', 'url', 'storage_path', 'status', 'moderation_status'],
      user,
      false,
    ),
    ['title', 'is_public'],
  );
  assert.equal(applyGalleryUpdateValues('gallery_items', { is_public: false }, user).published_at, null);
  assert.ok(applyGalleryUpdateValues('gallery_items', { is_public: true }, user).published_at);
});

