/**
 * Playlist Generator
 * Reads tracks from get_radio_smart_queue() and writes /tmp/radio_playlist.m3u
 *
 * Priority for audio URLs:
 *   1. Local file on the mounted volume (/opt/aimuza/data/uploads/...)
 *   2. HTTP URL via internal Docker network
 *   3. Public HTTPS URL (last resort — requires external DNS)
 */

const fs = require('fs');
const path = require('path');

const PLAYLIST_PATH = '/tmp/radio_playlist.m3u';
const LOCAL_STORAGE = process.env.LOCAL_STORAGE_PATH || '/opt/aimuza/data/uploads';
const PUBLIC_BASE = process.env.PUBLIC_BASE_URL || process.env.BASE_URL || 'https://aimuza.ru';
const STORAGE_URL_PREFIX = process.env.STORAGE_BASE_URL || 'https://aimuza.ru/storage/v1/object/public';

function resolveAudioUrl(raw) {
  if (!raw) return null;

  // Full URL → try to map to local file first
  if (raw.startsWith('http')) {
    const local = tryMapToLocal(raw);
    if (local) return local;
    return raw;
  }

  // Absolute storage path (e.g. /storage/v1/object/public/tracks/...)
  if (raw.startsWith('/storage/v1/object/public/')) {
    const suffix = raw.replace('/storage/v1/object/public/', '');
    const local = path.join(LOCAL_STORAGE, suffix);
    if (fs.existsSync(local)) return local;
    return PUBLIC_BASE + raw;
  }

  if (raw.startsWith('/')) {
    const local = path.join(LOCAL_STORAGE, raw);
    if (fs.existsSync(local)) return local;
    return PUBLIC_BASE + raw;
  }

  // Relative path → look on local disk
  const localDirect = path.join(LOCAL_STORAGE, raw);
  if (fs.existsSync(localDirect)) return localDirect;

  const localTracks = path.join(LOCAL_STORAGE, 'tracks', raw);
  if (fs.existsSync(localTracks)) return localTracks;

  // Fallback to public URL
  return STORAGE_URL_PREFIX + '/tracks/' + raw;
}

function tryMapToLocal(url) {
  if (!LOCAL_STORAGE) return null;

  // https://aimuza.ru/storage/v1/object/public/tracks/abc.mp3 → /opt/aimuza/data/uploads/tracks/abc.mp3
  if (STORAGE_URL_PREFIX && url.startsWith(STORAGE_URL_PREFIX)) {
    const suffix = url.slice(STORAGE_URL_PREFIX.length).replace(/^\//, '');
    const local = path.join(LOCAL_STORAGE, suffix);
    if (fs.existsSync(local)) return local;
  }

  // Generic pattern: .../storage/v1/object/public/...
  const storageIdx = url.indexOf('/storage/v1/object/public/');
  if (storageIdx !== -1) {
    const suffix = url.slice(storageIdx + '/storage/v1/object/public/'.length);
    const local = path.join(LOCAL_STORAGE, suffix);
    if (fs.existsSync(local)) return local;
  }

  return null;
}

function resolveCoverUrl(raw) {
  if (!raw) return '';
  if (raw.startsWith('http')) return raw;
  if (raw.startsWith('/')) return PUBLIC_BASE + raw;
  return PUBLIC_BASE + '/storage/v1/object/public/tracks/' + raw;
}

async function generatePlaylist(pool) {
  const { rows } = await pool.query(
    "SELECT * FROM public.get_radio_smart_queue(NULL, NULL, 50)"
  );

  if (!rows || rows.length === 0) {
    console.log('[Playlist] No tracks returned from smart queue');
    return 0;
  }

  const lines = ['#EXTM3U'];
  let localCount = 0;
  let remoteCount = 0;

  for (const track of rows) {
    const audioUrl = resolveAudioUrl(track.audio_url);
    if (!audioUrl) {
      console.warn('[Playlist] Skipping track without audio_url:', track.track_id);
      continue;
    }

    const isLocal = audioUrl.startsWith('/');
    if (isLocal) localCount++; else remoteCount++;

    const coverUrl = resolveCoverUrl(track.cover_url);
    const duration = Math.round(track.duration || 180);
    const title = (track.title || 'Unknown').replace(/"/g, "'");
    const artist = (track.author_username || 'AI Generated').replace(/"/g, "'");

    lines.push('#EXTINF:' + duration + ',' + artist + ' - ' + title);
    lines.push(
      'annotate:title="' + title + '",artist="' + artist + '",track_id="' + track.track_id + '",' +
      'cover_url="' + coverUrl + '",duration="' + duration + '",' +
      'chance_score="' + (track.chance_score || 0) + '",is_boosted="' + (track.is_boosted || false) + '"' +
      ':' + audioUrl
    );
  }

  fs.writeFileSync(PLAYLIST_PATH, lines.join('\n'), 'utf-8');
  console.log('[Playlist] Written ' + rows.length + ' tracks (' + localCount + ' local, ' + remoteCount + ' remote)');
  return rows.length;
}

module.exports = { generatePlaylist, PLAYLIST_PATH };
