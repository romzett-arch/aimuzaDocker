/**
 * Playlist Generator
 * Reads tracks from get_radio_smart_queue() and writes /tmp/radio_playlist.m3u
 * FIX: при пустой очереди всегда пишем #EXTM3U, чтобы Liquidsoap не падал на парсинге.
 */

const fs = require('fs');
const path = require('path');

const PLAYLIST_PATH = '/tmp/radio_playlist.m3u';
const PLAYLIST_TMP_PATH = '/tmp/radio_playlist.m3u.tmp';
const STORAGE_BASE = process.env.STORAGE_BASE_URL || 'https://aimuza.ru/storage/v1/object/public';
const LOCAL_STORAGE_PATH = process.env.LOCAL_STORAGE_PATH || '/opt/aimuza/data/uploads';
const STORAGE_URL_PREFIX = '/storage/v1/object/public/';
// Matches full public HTTPS/HTTP storage URLs, e.g. https://aimuza.ru/storage/v1/object/public/tracks/...
const STORAGE_HTTP_RE = /^https?:\/\/[^/]+\/storage\/v1\/object\/public\//;

function resolveAudioUrl(rawUrl = '') {
  if (STORAGE_HTTP_RE.test(rawUrl)) {
    const relPath = rawUrl.replace(STORAGE_HTTP_RE, '');
    const localPath = path.join(LOCAL_STORAGE_PATH, relPath);
    return fs.existsSync(localPath) ? localPath : rawUrl;
  }
  if (rawUrl.startsWith('/') && rawUrl.includes(STORAGE_URL_PREFIX)) {
    const relPath = rawUrl.substring(rawUrl.indexOf(STORAGE_URL_PREFIX) + STORAGE_URL_PREFIX.length);
    const localPath = path.join(LOCAL_STORAGE_PATH, relPath);
    return fs.existsSync(localPath) ? localPath : `${STORAGE_BASE}/${relPath}`;
  }
  if (rawUrl.startsWith('http')) return rawUrl;
  const localPath = path.join(LOCAL_STORAGE_PATH, 'tracks', rawUrl);
  return fs.existsSync(localPath) ? localPath : `${STORAGE_BASE}/tracks/${rawUrl}`;
}

async function generatePlaylist(pool) {
  try {
    const { rows } = await pool.query(
      "SELECT * FROM public.get_radio_smart_queue(NULL::uuid, NULL::uuid, 50)"
    );

    const content = (!rows || rows.length === 0)
      ? '#EXTM3U\n'
      : (() => {
          const lines = ['#EXTM3U'];
          for (const track of rows) {
            const audioUrl = resolveAudioUrl(track.audio_url || '');

            const duration = Math.round(track.duration || 180);
            const title = (track.title || 'Unknown').replace(/"/g, "'");
            const artist = (track.author_username || 'AI Generated').replace(/"/g, "'");

            lines.push(`#EXTINF:${duration},${artist} - ${title}`);
            lines.push(
              `annotate:title="${title}",artist="${artist}",track_id="${track.track_id}",` +
              `cover_url="${track.cover_url || ''}",duration="${duration}",` +
              `chance_score="${track.chance_score}",is_boosted="${track.is_boosted || false}",` +
              `source="${track.source || 'algorithm'}"` +
              `:${audioUrl}`
            );
          }
          return lines.join('\n');
        })();

    if (!rows || rows.length === 0) {
      fs.writeFileSync(PLAYLIST_PATH, content, 'utf-8');
      console.log('[Playlist] No tracks — wrote minimal #EXTM3U');
      return 0;
    }

    fs.writeFileSync(PLAYLIST_TMP_PATH, content, 'utf-8');
    fs.renameSync(PLAYLIST_TMP_PATH, PLAYLIST_PATH);
    console.log(`[Playlist] Written ${rows.length} tracks to ${PLAYLIST_PATH}`);
    return rows.length;
  } catch (error) {
    console.error('[Playlist] Error:', error.message);
    try {
      fs.writeFileSync(PLAYLIST_PATH, '#EXTM3U\n', 'utf-8');
    } catch (e) {}
    return 0;
  }
}

module.exports = { generatePlaylist, resolveAudioUrl, PLAYLIST_PATH };
