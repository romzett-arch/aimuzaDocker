const fs = require('fs');
const path = require('path');
const { generatePlaylist } = require('./lib/playlist');
const liquidsoap = require('./lib/liquidsoap');

async function refreshPlaylist(pool, metadataWs) {
  try {
    const count = await generatePlaylist(pool);
    if (count > 0) {
      const { rows } = await pool.query(
        "SELECT * FROM public.get_radio_smart_queue(NULL, NULL, 20)"
      );
      metadataWs.setQueue(rows || []);
    }
  } catch (error) {
    console.error('[Playlist] Error:', error.message);
  }
}

async function resolvePredictions(pool, metadataWs) {
  try {
    const result = await pool.query("SELECT public.radio_resolve_predictions()");
    const count = result.rows[0]?.radio_resolve_predictions || 0;
    if (count > 0) {
      console.log('[Predictions] Resolved ' + count);
      metadataWs.broadcast({ type: 'predictions_resolved', data: { count } });
    }
  } catch (error) {
    console.error('[Predictions] Error:', error.message);
  }
}

async function manageAuctionSlots(pool, metadataWs) {
  try {
    await pool.query(`
      UPDATE public.radio_slots SET status = 'completed'
      WHERE status = 'open' AND ends_at < NOW()
    `);

    await pool.query(`
      UPDATE public.radio_slots SET status = 'completed'
      WHERE status = 'playing' AND ends_at < NOW()
    `);

    const { rows: winners } = await pool.query(`
      UPDATE public.radio_slots s
      SET winner_user_id = b.user_id, winner_track_id = b.track_id,
          winning_bid = b.amount, status = 'won'
      FROM public.radio_bids b
      WHERE s.status = 'bidding' AND s.ends_at <= NOW()
        AND b.slot_id = s.id AND b.status = 'active'
        AND b.amount = (SELECT MAX(b2.amount) FROM public.radio_bids b2
                        WHERE b2.slot_id = s.id AND b2.status = 'active')
      RETURNING s.id, b.track_id, b.user_id
    `);

    for (const winner of winners || []) {
      try {
        const refundResult = await pool.query(
          'SELECT public.radio_refund_losers($1) AS refunded',
          [winner.id]
        );
        const refunded = refundResult?.rows?.[0]?.refunded || 0;
        if (refunded > 0) {
          console.log('[Auction] Refunded ' + refunded + ' losing bids for slot ' + winner.id);
        }
      } catch (refErr) {
        console.error('[Auction] Refund error for slot ' + winner.id + ':', refErr.message);
      }
    }

    const LOCAL_STORAGE = process.env.LOCAL_STORAGE_PATH || '/opt/aimuza/data/uploads';
    const STORAGE_PREFIX = '/storage/v1/object/public/';

    for (const winner of winners || []) {
      const { rows: trackRows } = await pool.query(
        'SELECT t.title, t.audio_url, t.cover_url, t.duration, p.username FROM public.tracks t LEFT JOIN public.profiles p ON p.user_id = t.user_id WHERE t.id = $1',
        [winner.track_id]
      );
      const track = trackRows?.[0];
      if (track) {
        const rawUrl = track.audio_url || '';
        let audioUrl;
        if (rawUrl.startsWith('/') && rawUrl.includes(STORAGE_PREFIX)) {
          const relPath = rawUrl.substring(rawUrl.indexOf(STORAGE_PREFIX) + STORAGE_PREFIX.length);
          const localPath = path.join(LOCAL_STORAGE, relPath);
          audioUrl = fs.existsSync(localPath) ? localPath : (process.env.STORAGE_BASE_URL || 'https://aimuza.ru/storage/v1/object/public') + '/' + relPath;
        } else if (rawUrl.startsWith('http')) {
          audioUrl = rawUrl;
        } else {
          const localPath = path.join(LOCAL_STORAGE, 'tracks', rawUrl);
          audioUrl = fs.existsSync(localPath) ? localPath : (process.env.STORAGE_BASE_URL || 'https://aimuza.ru/storage/v1/object/public') + '/tracks/' + rawUrl;
        }

        await liquidsoap.pushTrack(audioUrl, {
          title: track.title,
          artist: track.username || 'AI Generated',
          track_id: winner.track_id,
          cover_url: track.cover_url || '',
          duration: String(track.duration || 180),
        });
        console.log('[Auction] Winner track pushed: ' + track.title);
      }
    }

    if (winners?.length > 0) {
      metadataWs.broadcast({ type: 'auction_update', data: {} });
    }

    const { rows: expiredBidding } = await pool.query(`
      UPDATE public.radio_slots SET status = 'completed'
      WHERE status = 'bidding' AND ends_at < NOW() AND winner_user_id IS NULL
      RETURNING id
    `);
    for (const expired of expiredBidding || []) {
      try {
        await pool.query('SELECT public.radio_refund_losers($1)', [expired.id]);
        console.log('[Auction] Refunded all bids for expired slot ' + expired.id);
      } catch (e) {
        console.error('[Auction] Refund error for expired slot:', e.message);
      }
    }

    try {
      const newSlotResult = await pool.query('SELECT public.radio_create_next_slot() AS new_id');
      const newId = newSlotResult?.rows?.[0]?.new_id;
      if (newId) {
        console.log('[Auction] Created new slot: ' + newId);
        metadataWs.broadcast({ type: 'auction_update', data: { new_slot: true } });
      }
    } catch (slotErr) {
      console.error('[Auction] Slot creation error:', slotErr.message);
    }
  } catch (error) {
    console.error('[Auction] Error:', error.message);
  }
}

module.exports = { refreshPlaylist, resolvePredictions, manageAuctionSlots };
