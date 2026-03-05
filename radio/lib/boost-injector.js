/**
 * Boost Injector
 * Checks track_promotions and pushes boosted tracks into Liquidsoap priority queue
 */

const fs = require('fs');
const path = require('path');
const liquidsoap = require('./liquidsoap');

const STORAGE_BASE = process.env.STORAGE_BASE_URL || process.env.PUBLIC_BASE_URL || 'https://aimuza.ru/storage/v1/object/public';
const LOCAL_STORAGE_PATH = process.env.LOCAL_STORAGE_PATH || '/opt/aimuza/data/uploads';
const STORAGE_URL_PREFIX = '/storage/v1/object/public/';

const injectedThisHour = new Map();

async function injectBoostedTracks(pool) {
  try {
    const { rows } = await pool.query(`
      SELECT tp.id AS promotion_id, tp.track_id, tp.boost_type,
             t.title, t.audio_url, t.cover_url, t.duration,
             p.username AS author_username
      FROM public.track_promotions tp
      JOIN public.tracks t ON t.id = tp.track_id
      LEFT JOIN public.profiles p ON p.user_id = t.user_id
      WHERE (tp.is_active = true OR tp.status = 'active') AND tp.expires_at > NOW()
      ORDER BY
        CASE tp.boost_type
          WHEN 'top' THEN 1
          WHEN 'premium' THEN 2
          ELSE 3
        END
      LIMIT 5
    `);

    if (!rows || rows.length === 0) return;

    const oneHourAgo = Date.now() - 3600000;
    for (const [id, time] of injectedThisHour) {
      if (time < oneHourAgo) injectedThisHour.delete(id);
    }

    for (const track of rows) {
      if (track.boost_type === 'standard') continue;

      const cooldownMs = track.boost_type === 'top' ? 3600000 : 7200000;
      const lastInjected = injectedThisHour.get(track.track_id) || 0;

      if (Date.now() - lastInjected < cooldownMs) continue;

      const rawUrl = track.audio_url || '';
      let audioUrl;
      if (rawUrl.startsWith('/') && rawUrl.includes(STORAGE_URL_PREFIX)) {
        const relPath = rawUrl.substring(rawUrl.indexOf(STORAGE_URL_PREFIX) + STORAGE_URL_PREFIX.length);
        const localPath = path.join(LOCAL_STORAGE_PATH, relPath);
        audioUrl = fs.existsSync(localPath) ? localPath : `${STORAGE_BASE}/${relPath}`;
      } else if (rawUrl.startsWith('http')) {
        audioUrl = rawUrl;
      } else {
        const localPath = path.join(LOCAL_STORAGE_PATH, 'tracks', rawUrl);
        audioUrl = fs.existsSync(localPath) ? localPath : `${STORAGE_BASE}/tracks/${rawUrl}`;
      }

      await liquidsoap.pushTrack(audioUrl, {
        title: track.title,
        artist: track.author_username || 'AI Generated',
        track_id: track.track_id,
        cover_url: track.cover_url || '',
        duration: String(track.duration || 180),
      });

      injectedThisHour.set(track.track_id, Date.now());

      await pool.query(
        'UPDATE public.track_promotions SET impressions = COALESCE(impressions, 0) + 1 WHERE id = $1',
        [track.promotion_id]
      ).catch(() => {});

      console.log(`[Boost] Injected ${track.boost_type} track: ${track.title}`);
    }
  } catch (error) {
    console.error('[Boost] Error:', error.message);
  }
}

module.exports = { injectBoostedTracks };
