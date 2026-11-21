import assert from 'node:assert/strict';
import test from 'node:test';
import sharp from 'sharp';
import { distributionCoverResolution, formatDistributionCover, isPaidReleaseCover } from '../src/services/distribution-cover.js';

test('distribution cover conversion always yields square 3000 × 3000 JPEG bytes', async () => {
  const source = await sharp({ create: { width: 320, height: 200, channels: 4, background: '#558822aa' } }).png().toBuffer();
  const picture = await formatDistributionCover(source);
  const { width, height, format, hasAlpha } = await sharp(picture).metadata();
  assert.deepEqual({ width, height, format, hasAlpha }, { width: 3000, height: 3000, format: 'jpeg', hasAlpha: false });
});

test('release package accepts a paid cover for its track or one awaiting its initial assignment', () => {
  const track = 'track-a';
  const cover = { status: 'completed', resolution: distributionCoverResolution, mime_type: 'image/jpeg', price_rub: 5, release_track_id: track };
  assert.equal(isPaidReleaseCover(cover, track), true);
  assert.equal(isPaidReleaseCover({ ...cover, release_track_id: null }, track), true);
  assert.equal(isPaidReleaseCover(cover, 'track-b'), false);
  for (const override of [{ price_rub: 0 }, { status: 'pending' }, { resolution: '2K' }, { mime_type: 'image/png' }]) {
    assert.equal(isPaidReleaseCover({ ...cover, ...override }, track), false);
  }
});
