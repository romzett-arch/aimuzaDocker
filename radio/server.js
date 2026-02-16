/**
 * Radio Service — Queue Worker, AFK Checker, Prediction Resolver, Ad Scheduler.
 * 
 * Runs in separate Docker container for independent scaling.
 * Connects to PostgreSQL for queue management and RPC calls.
 */

const { Pool } = require('pg');

// ─── Config ───────────────────────────────────────────────────

const DB_HOST = process.env.DB_HOST || 'db';
const DB_PORT = process.env.DB_PORT || 5432;
const DB_NAME = process.env.DB_NAME || 'aimuza';
const DB_USER = process.env.DB_USER || 'aimuza';
const DB_PASSWORD = process.env.DB_PASSWORD || 'password';

const QUEUE_INTERVAL_MS = parseInt(process.env.QUEUE_INTERVAL_MS || '5000');
const PREDICTION_RESOLVE_INTERVAL_MS = parseInt(process.env.PREDICTION_RESOLVE_INTERVAL_MS || '60000');

const pool = new Pool({
  host: DB_HOST,
  port: DB_PORT,
  database: DB_NAME,
  user: DB_USER,
  password: DB_PASSWORD,
  max: 5,
});

// ─── Queue Worker ─────────────────────────────────────────────

async function refreshQueue() {
  try {
    // Call get_radio_smart_queue to populate the queue
    const result = await pool.query(
      "SELECT * FROM public.get_radio_smart_queue(NULL, NULL, 50)"
    );
    
    // Clear old unplayed items and insert fresh ones
    await pool.query("DELETE FROM public.radio_queue WHERE NOT is_played AND created_at < NOW() - INTERVAL '10 minutes'");
    
    if (result.rows.length > 0) {
      // Only insert if queue is getting low
      const { rows: [{ count }] } = await pool.query(
        "SELECT COUNT(*) FROM public.radio_queue WHERE NOT is_played"
      );
      
      if (parseInt(count) < 10) {
        console.log(`[Queue] Refreshing queue with ${result.rows.length} tracks (queue was ${count})`);
        // Insert top tracks into queue using parameterized queries (no SQL injection)
        for (let i = 0; i < Math.min(result.rows.length, 20); i++) {
          const row = result.rows[i];
          await pool.query(
            `INSERT INTO public.radio_queue (track_id, user_id, source, position, chance_score, quality_component, xp_component, freshness_component, discovery_component)
             VALUES ($1, $2, 'algorithm', $3, $4, $5, $6, $7, $8)
             ON CONFLICT DO NOTHING`,
            [row.track_id, row.author_id, i, 
             parseFloat(row.chance_score) || 0, 
             parseFloat(row.quality_component) || 0, 
             parseFloat(row.xp_component) || 0, 
             parseFloat(row.freshness_component) || 0, 
             parseFloat(row.discovery_component) || 0]
          );
        }
      }
    }
  } catch (error) {
    console.error('[Queue] Error refreshing queue:', error.message);
  }
}

// ─── Prediction Resolver ──────────────────────────────────────

async function resolvePredictions() {
  try {
    const result = await pool.query("SELECT public.radio_resolve_predictions()");
    const count = result.rows[0]?.radio_resolve_predictions || 0;
    if (count > 0) {
      console.log(`[Predictions] Resolved ${count} predictions`);
    }
  } catch (error) {
    console.error('[Predictions] Error resolving:', error.message);
  }
}

// ─── Auction Slot Manager ─────────────────────────────────────

async function manageAuctionSlots() {
  try {
    // Close expired bidding slots
    const { rowCount: closedCount } = await pool.query(`
      UPDATE public.radio_slots 
      SET status = 'completed'
      WHERE status IN ('bidding', 'playing') AND ends_at < NOW()
    `);
    if (closedCount > 0) {
      console.log(`[Auction] Closed ${closedCount} expired slots`);
    }

    // Award winning bids for closed slots
    await pool.query(`
      UPDATE public.radio_slots s
      SET winner_user_id = b.user_id, winner_track_id = b.track_id, winning_bid = b.amount, status = 'won'
      FROM public.radio_bids b
      WHERE s.status = 'bidding' AND s.starts_at <= NOW()
        AND b.slot_id = s.id AND b.status = 'active'
        AND b.amount = (SELECT MAX(b2.amount) FROM public.radio_bids b2 WHERE b2.slot_id = s.id AND b2.status = 'active')
    `);
  } catch (error) {
    console.error('[Auction] Error managing slots:', error.message);
  }
}

// ─── Voting Resolver ──────────────────────────────────────────

const VOTING_RESOLVE_INTERVAL_MS = parseInt(process.env.VOTING_RESOLVE_INTERVAL_MS || '60000'); // 1 min

async function resolveExpiredVoting() {
  try {
    // Find tracks with expired voting period
    const { rows: expiredTracks } = await pool.query(`
      SELECT id, title, voting_likes_count, voting_dislikes_count, user_id
      FROM public.tracks
      WHERE moderation_status = 'voting' AND voting_ends_at < NOW()
    `);

    if (expiredTracks.length === 0) return;

    console.log(`[Voting] Processing ${expiredTracks.length} expired voting tracks`);

    // Get voting settings
    const { rows: settings } = await pool.query(`
      SELECT key, value FROM public.settings
      WHERE key IN ('voting_min_votes', 'voting_approval_ratio')
    `);
    const settingsMap = new Map(settings.map(s => [s.key, s.value]));
    const minVotes = parseInt(settingsMap.get('voting_min_votes') || '10', 10);
    const approvalRatio = parseFloat(settingsMap.get('voting_approval_ratio') || '0.6');

    for (const track of expiredTracks) {
      const likes = track.voting_likes_count || 0;
      const dislikes = track.voting_dislikes_count || 0;
      const totalVotes = likes + dislikes;
      let votingResult, newStatus, reason;

      if (totalVotes < minVotes) {
        votingResult = 'rejected';
        newStatus = 'rejected';
        reason = `Недостаточно голосов: ${totalVotes} из ${minVotes} минимальных`;
      } else {
        const likeRatio = likes / totalVotes;
        if (likeRatio >= approvalRatio) {
          votingResult = 'voting_approved';
          newStatus = 'pending'; // Back to moderation queue for final label decision
          reason = `Голосование пройдено: ${Math.round(likeRatio * 100)}% положительных`;
        } else {
          votingResult = 'rejected';
          newStatus = 'rejected';
          reason = `Отклонено: ${Math.round(likeRatio * 100)}% положительных (нужно ${Math.round(approvalRatio * 100)}%)`;
        }
      }

      // Update track
      await pool.query(`
        UPDATE public.tracks
        SET moderation_status = $1, voting_result = $2, is_public = false
        WHERE id = $3
      `, [newStatus, votingResult, track.id]);

      // Notify user
      if (track.user_id) {
        const notifTitle = votingResult === 'voting_approved'
          ? '🎉 Голосование пройдено!'
          : 'Голосование завершено';
        const notifMsg = votingResult === 'voting_approved'
          ? `Трек "${track.title}" успешно прошёл голосование и отправлен на финальное рассмотрение.`
          : `Трек "${track.title}" не набрал достаточно голосов. ${reason}`;

        await pool.query(`
          INSERT INTO public.notifications (user_id, type, title, message, target_type, target_id)
          VALUES ($1, 'voting_result', $2, $3, 'track', $4)
        `, [track.user_id, notifTitle, notifMsg, track.id]);
      }

      console.log(`[Voting] Track "${track.title}" (${track.id}): ${votingResult} -> ${newStatus}`);
    }
  } catch (error) {
    console.error('[Voting] Error resolving expired voting:', error.message);
  }
}

// ─── Internal Voting Resolver ─────────────────────────────────

async function resolveExpiredInternalVoting() {
  try {
    // Find tracks with expired internal voting
    const { rows: expiredTracks } = await pool.query(`
      SELECT id, title, user_id
      FROM public.tracks
      WHERE moderation_status = 'voting' 
        AND voting_type = 'internal'
        AND voting_ends_at < NOW()
    `);

    if (expiredTracks.length === 0) return;

    console.log(`[InternalVoting] Processing ${expiredTracks.length} expired internal voting tracks`);

    for (const track of expiredTracks) {
      try {
        // Call the RPC function to resolve
        await pool.query(`SELECT public.resolve_internal_voting($1)`, [track.id]);
        console.log(`[InternalVoting] Resolved track "${track.title}" (${track.id})`);
      } catch (err) {
        console.error(`[InternalVoting] Failed to resolve track ${track.id}:`, err.message);
      }
    }
  } catch (error) {
    console.error('[InternalVoting] Error:', error.message);
  }
}

// ─── Stale Moderation Lock Cleanup ───────────────────────────

async function cleanupStaleModerationLocks() {
  try {
    const { rowCount } = await pool.query(`
      UPDATE public.tracks
      SET moderation_locked_by = NULL, moderation_locked_at = NULL
      WHERE moderation_locked_by IS NOT NULL
        AND moderation_locked_at < NOW() - interval '30 minutes'
    `);
    if (rowCount > 0) {
      console.log(`[Moderation] Cleaned up ${rowCount} stale moderation locks`);
    }
  } catch (error) {
    console.error('[Moderation] Error cleaning locks:', error.message);
  }
}

// ─── Health Check ─────────────────────────────────────────────

const http = require('http');
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'ok', service: 'aimuza-radio', uptime: process.uptime() }));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});

const PORT = process.env.PORT || 3200;

// ─── Main Loop ────────────────────────────────────────────────

async function main() {
  console.log('═══════════════════════════════════════════');
  console.log(' AIMUZA Radio Service v2.0');
  console.log(`  DB: ${DB_HOST}:${DB_PORT}/${DB_NAME}`);
  console.log(`  Queue interval: ${QUEUE_INTERVAL_MS}ms`);
  console.log(`  Prediction resolve interval: ${PREDICTION_RESOLVE_INTERVAL_MS}ms`);
  console.log(`  Voting resolve interval: ${VOTING_RESOLVE_INTERVAL_MS}ms`);
  console.log('═══════════════════════════════════════════');

  // Test DB connection
  try {
    await pool.query('SELECT 1');
    console.log('[DB] Connected successfully');
  } catch (error) {
    console.error('[DB] Connection failed:', error.message);
    process.exit(1);
  }

  // Start health check server
  server.listen(PORT, () => {
    console.log(`[Health] Listening on port ${PORT}`);
  });

  // Start workers
  setInterval(refreshQueue, QUEUE_INTERVAL_MS);
  setInterval(resolvePredictions, PREDICTION_RESOLVE_INTERVAL_MS);
  setInterval(manageAuctionSlots, 30000); // Check every 30s
  setInterval(resolveExpiredVoting, VOTING_RESOLVE_INTERVAL_MS); // Check every 1 min
  setInterval(resolveExpiredInternalVoting, VOTING_RESOLVE_INTERVAL_MS); // Internal voting every 1 min
  setInterval(cleanupStaleModerationLocks, 300000); // Cleanup stale locks every 5 min

  // Initial run
  await refreshQueue();
  await resolvePredictions();
  await manageAuctionSlots();
  await resolveExpiredVoting();
  await resolveExpiredInternalVoting();
  await cleanupStaleModerationLocks();

  console.log('[Radio] All workers started');
}

main().catch(console.error);
