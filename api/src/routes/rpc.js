/**
 * RPC Routes — вызов PostgreSQL функций
 * POST /rest/v1/rpc/:function_name
 * Body: { param1: val1, param2: val2 }
 */
import { Router } from 'express';
import { pool } from '../db.js';
import { rpcAnonLimiter, votingIpLimiter, votingUserLimiter } from '../middleware/votingRateLimit.js';

const router = Router();

const ALLOWED_RPC = new Set([
  'accept_role_invitation', 'add_user_credits', 'admin_add_xp',   'admin_annul_vote', 'admin_approve_purchase',
  'admin_end_voting_early', 'admin_extend_promotion', 'admin_get_active_votings',
  'admin_get_all_promotions', 'admin_get_deal_blockchain_info', 'admin_get_deal_content',
  'admin_get_flagged_votes', 'admin_get_voting_dashboard', 'admin_grant_user_income',
  'admin_reject_purchase', 'admin_review_flagged_votes', 'admin_stop_promotion',
  'aggregate_votes_to_tracks',
  'approve_verification', 'assess_vote_fraud', 'award_contest_prize', 'award_xp',
  'block_user', 'block_user_in_messages', 'calculate_chart_scores', 'calculate_track_quality',
  'can_write_during_maintenance', 'cast_radio_vote_for_arena', 'cast_weighted_vote',
  'check_achievements_after_finalize', 'check_contest_achievements',
  'check_maintenance_access', 'check_user_achievements', 'check_voting_eligibility',
  'close_admin_conversation', 'close_voting_topic_on_rejection',
  'create_admin_conversation', 'create_conversation_with_user',
  'create_voting_forum_topic', 'deactivate_expired_promotions', 'debit_balance', 'debit_for_generation',
  'deduct_user_xp', 'delete_forum_topic_cascade', 'finalize_contest',
  'finalize_contest_winners', 'find_similar_qa_tickets', 'find_user_by_short_id',
  'fn_add_xp', 'forum_authority_leaderboard', 'forum_boost_topic',
  'forum_calculate_content_quality', 'forum_find_similar_topics', 'forum_get_hub_stats',
  'forum_get_leaderboard', 'forum_get_user_profile', 'forum_increment_topic_views',
  'forum_mark_read', 'forum_mark_solution', 'forum_moderate_promo',
  'forum_recalculate_authority', 'forum_search', 'forum_update_category_on_topic',
  'forum_update_topic_on_post', 'forum_update_user_stats_on_post',
  'forum_update_user_stats_on_topic', 'forum_user_is_banned',
  'generate_share_token', 'get_ad_for_slot', 'get_boosted_tracks',
  'get_contest_leaderboard', 'get_creator_earnings_profile', 'get_economy_health',
  'get_direct_message_state', 'get_feed_tracks_with_profiles', 'get_hero_stats', 'get_last_messages',
  'get_marketplace_items', 'get_or_create_referral_code', 'get_qa_dashboard_stats',
  'get_qa_leaderboard', 'get_radio_listeners', 'get_radio_smart_queue',
  'get_radio_stats', 'get_radio_xp_today', 'get_recent_voters',
  'get_reputation_leaderboard', 'get_reputation_profile', 'get_smart_feed',
  'get_track_by_share_token', 'get_track_prompt_if_accessible',
  'get_track_prompt_info', 'get_unread_counts', 'get_user_block_info',
  'get_user_contest_rating', 'get_user_emails', 'get_user_role',
  'get_user_stats', 'get_user_vote_weight', 'get_velocity_tracks',
  'get_voter_profile', 'get_voting_live_stats', 'has_permission',
  'has_purchased_item', 'has_purchased_prompt', 'has_role',
  'hide_contest_comment', 'hide_track_comment', 'increment_promotion_click',
  'increment_promotion_impression', 'increment_prompt_downloads',
  'is_admin', 'is_maintenance_active', 'is_maintenance_whitelisted',
  'is_participant_in_conversation', 'is_super_admin', 'is_user_blocked',
  'pin_comment', 'process_payment_completion', 'process_payment_refund',
  'process_store_item_purchase', 'purchase_ad_free', 'purchase_track_boost',
  'qa_recalculate_priority', 'qa_update_tester_tier',
  'radio_award_listen_xp', 'radio_create_next_slot', 'radio_heartbeat',
  'radio_place_bid', 'radio_place_prediction', 'radio_skip_ad',
  'cancel_subscription_with_refund', 'check_deposit_limit', 'check_track_upload_limit',
  'get_my_radio_stats', 'get_user_subscription_tier', 'purchase_track_upload_pack', 'record_track_upload',
  'subscribe_to_plan', 'reorder_user_tracks',
  'recalculate_feed_scores', 'record_ad_click', 'record_ad_impression',
  'resolve_qa_ticket', 'resolve_track_voting', 'revoke_share_token',
  'revoke_verification', 'revoke_vote', 'safe_award_xp',
  'send_track_to_voting', 'submit_contest_entry', 'take_voting_snapshot',
  'unblock_user', 'unblock_user_in_messages', 'unhide_contest_comment', 'update_last_seen',
  'update_voter_ranks', 'vote_qa_ticket', 'withdraw_contest_entry',
]);

/** Общий rate limit для анонимов — на все RPC */
const anonThenVoting = (req, res, next) => {
  rpcAnonLimiter(req, res, (err) => {
    if (err) return next(err);
    votingRateLimit(req, res, next);
  });
};

/** Rate limit только для cast_weighted_vote */
function votingRateLimit(req, res, next) {
  if (req.params.fn !== 'cast_weighted_vote') return next();
  votingIpLimiter(req, res, (err) => {
    if (err) return next(err);
    votingUserLimiter(req, res, next);
  });
}

async function handleRpc(req, res) {
  const client = await pool.connect();
  try {
    const fnName = req.params.fn;
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(fnName)) {
      return res.status(400).json({ error: 'Invalid function name' });
    }

    if (!ALLOWED_RPC.has(fnName)) {
      return res.status(403).json({ error: 'Function not allowed', code: 'RPC_FORBIDDEN' });
    }

    // ── Транзакция: set_config + вызов функции должны быть в одной TX ──
    // Без BEGIN/COMMIT set_config(is_local=true) теряется между autocommit-запросами
    await client.query('BEGIN');

    if (req.user && req.user.id && req.user.id !== 'service-role') {
      await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [req.user.id]);
      await client.query(`SELECT set_config('request.jwt.claim.role', $1, true)`, [req.user.role || 'authenticated']);
      if (req.user.email) {
        await client.query(`SELECT set_config('request.jwt.claim.email', $1, true)`, [req.user.email]);
      }
    }

    const params = (req.method === 'GET') ? req.query : (req.body || {});
    const KEY_REGEX = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
    const keys = Object.keys(params).filter(k =>
      !['select', 'order', 'limit', 'offset'].includes(k) && KEY_REGEX.test(k)
    );
    const rejectedKeys = Object.keys(params).filter(k =>
      !['select', 'order', 'limit', 'offset'].includes(k) && !KEY_REGEX.test(k)
    );
    if (rejectedKeys.length > 0) {
      return res.status(400).json({ error: 'Invalid parameter names', rejected: rejectedKeys });
    }

    let sql;
    let sqlParams;

    if (keys.length === 0) {
      sql = `SELECT * FROM public.${fnName}()`;
      sqlParams = [];
    } else {
      const namedParams = keys.map((k, i) => `"${k}" := $${i + 1}`);
      sql = `SELECT * FROM public.${fnName}(${namedParams.join(', ')})`;
      sqlParams = keys.map(k => {
        const v = params[k];
        if (Array.isArray(v)) {
          return `{${v.join(',')}}`;
        }
        return (v !== null && typeof v === 'object') ? JSON.stringify(v) : v;
      });
    }

    const result = await client.query(sql, sqlParams);

    await client.query('COMMIT');

    // Если функция возвращает одну строку с одной колонкой — возвращаем значение напрямую
    if (result.rows.length === 1 && result.fields.length === 1) {
      const val = result.rows[0][result.fields[0].name];
      return res.json(val);
    }

    res.json(result.rows);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    // Return null only for "function does not exist" (PostgREST compatibility)
    if (err.message.includes('function') && err.message.includes('does not exist')) {
      return res.json(null);
    }
    console.error('[RPC]', req.params.fn, err.message);
    const safeMsg = err.message?.startsWith('RAISE:') || err.message?.includes('Insufficient') || err.message?.includes('Unauthorized')
      ? err.message : 'RPC call failed';
    res.status(400).json({ message: safeMsg, error: safeMsg, code: 'RPC_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
}

router.post('/:fn', anonThenVoting, handleRpc);

export default router;
