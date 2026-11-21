import sharp from 'sharp';
import { pool } from '../db.js';
import { getGeneratedImage } from './image-generation.js';

export const distributionCoverResolution = '3000x3000';

export function isPaidReleaseCover(cover, trackId) {
  return cover?.status === 'completed' && cover.resolution === distributionCoverResolution &&
    cover.mime_type === 'image/jpeg' && cover.price_rub > 0 &&
    (cover.release_track_id === null || cover.release_track_id === trackId);
}

export async function releaseCoverOptions(userId, trackId) {
  const { rows } = await pool.query(
    `SELECT id, prompt, created_at FROM public.image_generation_jobs
     WHERE user_id=$1 AND status='completed' AND price_rub>0 AND mime_type='image/jpeg'
       AND resolution=$3 AND image IS NOT NULL AND (release_track_id IS NULL OR release_track_id=$2)
       AND EXISTS (SELECT 1 FROM public.tracks WHERE id=$2 AND user_id=$1 AND status='completed')
     ORDER BY (release_track_id IS NOT NULL) DESC, created_at DESC, id DESC LIMIT 20`,
    [userId, trackId, distributionCoverResolution],
  );
  return rows;
}

export async function loadPaidReleaseCover(userId, coverId, trackId) {
  const normalizedTrackId = trackId.toLowerCase();
  const cover = await getGeneratedImage(userId, coverId);
  if (!cover?.image || !isPaidReleaseCover(cover, normalizedTrackId)) return null;

  const dimensions = await sharp(cover.image, { limitInputPixels: 20_000_000 }).metadata().catch(() => null);
  if (dimensions?.format !== 'jpeg' || dimensions.width !== 3000 || dimensions.height !== 3000) return null;
  if (cover.release_track_id === normalizedTrackId) return cover.image;

  // Older clients generated paid covers without passing a track ID. Claim one once,
  // even if the same cover is submitted concurrently for two releases.
  const claim = await pool.query(
    `UPDATE public.image_generation_jobs SET release_track_id=$3
     WHERE user_id=$1 AND id=$2 AND (release_track_id IS NULL OR release_track_id=$3)
       AND EXISTS (SELECT 1 FROM public.tracks WHERE id=$3 AND user_id=$1 AND status='completed')`,
    [userId, coverId, normalizedTrackId],
  );
  return claim.rowCount ? cover.image : null;
}

export async function prepareDistributionCover(bytes) {
  return sharp(bytes, { limitInputPixels: 20_000_000 })
    .autoOrient()
    .resize(3000, 3000, { fit: 'cover', position: 'centre', kernel: 'lanczos3' })
    .flatten({ background: '#ffffff' })
    .toColourspace('srgb')
    .jpeg({ quality: 95, chromaSubsampling: '4:4:4' })
    .toBuffer();
}
