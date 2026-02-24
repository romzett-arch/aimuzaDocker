const { checkAdBreak } = require('./lib/ad-scheduler');

const ICECAST_STATUS_URL = 'http://127.0.0.1:8000/status-json.xsl';

async function handleTrackChanged(pool, metadataWs, getRadioConfig, trackData) {
  console.log('[Track] Changed: ' + trackData.title + ' — ' + trackData.artist);

  const PUBLIC_BASE = process.env.PUBLIC_BASE_URL || process.env.BASE_URL || '';

  let enriched = { ...trackData };
  if (trackData.track_id) {
    try {
      const { rows } = await pool.query(
        'SELECT t.id AS track_id, t.title, t.cover_url, t.duration, p.username AS artist, p.avatar_url AS author_avatar FROM public.tracks t LEFT JOIN public.profiles p ON p.user_id = t.user_id WHERE t.id = $1',
        [trackData.track_id]
      );
      if (rows[0]) {
        enriched = { ...enriched, ...rows[0] };
      }
    } catch (e) {
      console.error('[Track] Enrich error:', e.message);
    }
  }

  if (enriched.cover_url && enriched.cover_url.startsWith('/') && PUBLIC_BASE) {
    enriched.cover_url = PUBLIC_BASE + enriched.cover_url;
  }

  metadataWs.setCurrentTrack(enriched);

  await checkAdBreak(pool, metadataWs, getRadioConfig());

  if (trackData.track_id) {
    await pool.query(
      'INSERT INTO public.radio_schedule (track_id, source, played_at) VALUES ($1, $2, NOW())',
      [trackData.track_id, trackData.source || 'algorithm']
    ).catch(() => {});
  }
}

async function updateListenerCount(metadataWs) {
  try {
    const response = await fetch(ICECAST_STATUS_URL).catch(() => null);
    if (response?.ok) {
      const status = await response.json();
      const source = status?.icestats?.source;
      let count = 0;
      if (Array.isArray(source)) {
        count = source.reduce((sum, s) => sum + (s.listeners || 0), 0);
      } else if (source) {
        count = source.listeners || 0;
      }
      metadataWs.setListenersCount(count);
    }
  } catch (_) {}
}

async function loadRadioConfig(pool, setConfig) {
  try {
    const { rows } = await pool.query("SELECT key, value FROM public.radio_config");
    const config = {};
    rows.forEach(row => {
      config[row.key] = typeof row.value === 'string' ? JSON.parse(row.value) : row.value;
    });
    setConfig(config);
  } catch (error) {
    console.error('[Config] Error loading:', error.message);
  }
}

async function getStats(pool, metadataWs) {
  try {
    const { rows } = await pool.query(`
      SELECT
        (SELECT COUNT(*) FROM public.radio_listens WHERE created_at > CURRENT_DATE) AS listens_today,
        (SELECT COUNT(DISTINCT user_id) FROM public.radio_listens WHERE created_at > CURRENT_DATE) AS unique_today,
        (SELECT COUNT(*) FROM public.radio_listens) AS listens_total,
        (SELECT COUNT(*) FROM public.radio_slots WHERE status IN ('open', 'bidding')) AS active_slots,
        (SELECT COUNT(*) FROM public.radio_predictions WHERE status = 'pending') AS pending_predictions
    `);
    const stats = rows[0] || {};
    return {
      ...stats,
      listeners_now: metadataWs.listenersCount,
      ws_clients: metadataWs.clients.size,
      current_track: metadataWs.currentTrack,
    };
  } catch (error) {
    return { error: error.message };
  }
}

module.exports = { handleTrackChanged, updateListenerCount, loadRadioConfig, getStats };
