import { pool } from '../db.js';

export async function recordMaxIdentity(maxId, input) {
  const observedAt = input?.observedAt;
  if (!Number.isSafeInteger(observedAt) || observedAt <= 0 || observedAt > Date.now() + 300_000) return null;
  const name = typeof input.name === 'string' ? input.name.trim().slice(0, 160) || null : null;
  const result = await pool.query(
    `UPDATE public.max_chat_profiles
     SET max_display_name = CASE WHEN $2::text IS NOT NULL AND (max_name_seen_at IS NULL OR max_name_seen_at <= $3)
                                 THEN $2 ELSE max_display_name END,
         max_name_seen_at = CASE WHEN $2::text IS NOT NULL THEN greatest(max_name_seen_at,$3) ELSE max_name_seen_at END,
         last_interaction_at = greatest(last_interaction_at,$3)
     WHERE max_id=$1`,
    [maxId, name, new Date(observedAt)],
  );
  return result.rowCount > 0;
}
