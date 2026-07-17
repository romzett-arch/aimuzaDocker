import test from 'node:test';
import assert from 'node:assert/strict';

import { isStorageObjectUpload } from '../src/security/storage-rate-limit.js';

test('counts binary object writes against the upload quota', () => {
  assert.equal(isStorageObjectUpload('POST', '/storage/v1/object/tracks/user/master.wav'), true);
  assert.equal(isStorageObjectUpload('PUT', '/storage/v1/object/tracks/user/master.wav?upsert=true'), true);
});

test('does not count signed and public URL helpers as uploads', () => {
  assert.equal(isStorageObjectUpload('POST', '/storage/v1/object/sign/tracks/user/master.wav'), false);
  assert.equal(isStorageObjectUpload('POST', '/storage/v1/object/public-url/tracks/user/master.wav'), false);
});

test('does not count downloads, deletes, or malformed object URLs as uploads', () => {
  assert.equal(isStorageObjectUpload('GET', '/storage/v1/object/public/tracks/user/master.wav'), false);
  assert.equal(isStorageObjectUpload('DELETE', '/storage/v1/object/tracks'), false);
  assert.equal(isStorageObjectUpload('POST', '/storage/v1/object/tracks'), false);
});
