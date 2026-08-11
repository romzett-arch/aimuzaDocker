import test from 'node:test';
import assert from 'node:assert/strict';

import { assertOwnedMediaPath } from '../src/security/storage-path-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };

test('allows users to manage files only in their own track and cover folders', () => {
  assert.doesNotThrow(() => assertOwnedMediaPath(user, 'tracks', 'user-1/song.mp3'));
  assert.doesNotThrow(() => assertOwnedMediaPath(user, 'covers', 'user-1/cover.webp'));
  assert.throws(
    () => assertOwnedMediaPath(user, 'tracks', 'user-2/song.mp3'),
    (error) => error.code === 'STORAGE_PATH_OWNERSHIP_REQUIRED',
  );
  assert.throws(
    () => assertOwnedMediaPath(user, 'covers', '../user-1/cover.webp'),
    (error) => error.code === 'STORAGE_PATH_OWNERSHIP_REQUIRED',
  );
  assert.throws(
    () => assertOwnedMediaPath(user, 'tracks', 'user-1/../user-2/song.mp3'),
    (error) => error.code === 'STORAGE_PATH_OWNERSHIP_REQUIRED',
  );
});

test('keeps special release paths delegated to the release ownership policy', () => {
  assert.doesNotThrow(() => assertOwnedMediaPath(user, 'tracks', 'silk-releases/user-1/release-1/master.wav'));
});

test('allows administrators and service workers to manage generated paths', () => {
  assert.doesNotThrow(() => assertOwnedMediaPath(
    { id: 'admin-1', role: 'authenticated', app_role: 'admin' },
    'tracks',
    'masters/track-1.mp3',
  ));
  assert.doesNotThrow(() => assertOwnedMediaPath(
    { id: 'service-role', role: 'service_role' },
    'tracks',
    'generated/track-1.mp3',
  ));
});
