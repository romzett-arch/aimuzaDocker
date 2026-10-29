import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { mediaKey, collectKeys, safeFile, unlinkMedia } from '../src/services/media-files.js';
import { protectedWav } from '../src/services/mediaLifecycle.js';

test('only canonical local media URLs become deletion identities', () => {
  assert.equal(mediaKey('https://aimuza.ru/storage/v1/object/public/tracks/wav/a.wav?q=1'), 'tracks/wav/a.wav');
  assert.equal(mediaKey('http://api:3000/storage/v1/object/tracks/a.mp3'), 'tracks/a.mp3');
  assert.equal(mediaKey('https://aimuza.ru/api/ffmpeg/output/processed_12.wav'), 'ffmpeg/processed_12.wav');
  for (const value of ['https://attacker.invalid/storage/v1/object/public/tracks/a.mp3', 'https://aimuza.ru/storage/v1/object/public/certificates/a.pdf', 'https://aimuza.ru/storage/v1/object/public/tracks/a%2f..%2fb.mp3', 'https://aimuza.ru/api/ffmpeg/output/.secret']) assert.equal(mediaKey(value), null);
});

test('nested addon results and explicit release storage paths are inventoried', () => {
  const keys = collectKeys({ result_urls: JSON.stringify({ vocal: 'https://aimuza.ru/storage/v1/object/public/tracks/stems/v.mp3' }), storage_bucket: 'tracks', storage_path: 'silk-releases/user/release/master.wav' });
  assert.deepEqual([...keys].sort(), ['tracks/silk-releases/user/release/master.wav', 'tracks/stems/v.mp3']);
});

test('WAV retention protects shared playback, packages, distribution and external live references', () => {
  const key = 'tracks/wav/test.wav';
  const row = { table_name: 'tracks', row_id: '1', payload: { wav_url: 'https://aimuza.ru/storage/v1/object/public/tracks/wav/test.wav' } };
  const refs = new Map([[key, [row]]]);
  const track = { distribution_status: 'none' };
  const tracks = new Map([['1', track]]);
  assert.equal(protectedWav(key, refs, tracks), false);
  for (const flag of ['has_package', 'has_distribution', 'is_release_candidate']) {
    track[flag] = true; assert.equal(protectedWav(key, refs, tracks), true); track[flag] = false;
  }
  track.distribution_status = 'approved'; assert.equal(protectedWav(key, refs, tracks), true); track.distribution_status = 'none';
  row.payload.audio_url = row.payload.wav_url; assert.equal(protectedWav(key, refs, tracks), true); delete row.payload.audio_url;
  refs.get(key).push({ table_name: 'silk_release_assets' }); assert.equal(protectedWav(key, refs, tracks), true);
});

test('physical cleanup is idempotent and rejects traversal, buckets and symlinks', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'aimuza-media-'));
  try {
    await fs.mkdir(path.join(root, 'tracks')); await fs.mkdir(path.join(root, 'ffmpeg'));
    await fs.writeFile(path.join(root, 'tracks/a.mp3'), 'audio');
    assert.equal(await unlinkMedia('tracks/a.mp3', { uploads: root }), true);
    assert.equal(await unlinkMedia('tracks/a.mp3', { uploads: root }), false);
    await assert.rejects(safeFile(root, '../secret'));
    await assert.rejects(unlinkMedia('certificates/a.pdf', { uploads: root }));
    await fs.symlink(root, path.join(root, 'tracks/link'), process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(safeFile(root, 'tracks/link/anything'), /symlink/);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
