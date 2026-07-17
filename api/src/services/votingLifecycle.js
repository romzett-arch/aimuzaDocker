import { pool } from '../db.js';

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const DAY = 24 * 60 * MINUTE;

async function runJob(name, sql, serviceRole = false) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (serviceRole) {
      await client.query(`SELECT set_config('request.jwt.claim.role', 'service_role', true)`);
    }
    const result = await client.query(sql);
    await client.query('COMMIT');
    const value = result.rows[0] ? Object.values(result.rows[0])[0] : null;
    console.log(`[Voting lifecycle] ${name} completed`, value ?? '');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`[Voting lifecycle] ${name} failed:`, error.message);
  } finally {
    client.release();
  }
}

function schedule(name, sql, intervalMs, serviceRole = false) {
  void runJob(name, sql, serviceRole);
  const timer = setInterval(() => void runJob(name, sql, serviceRole), intervalMs);
  timer.unref();
}

/**
 * Служебные задачи запускаются внутри API и недоступны через публичный proxy.
 * SQL-функции идемпотентны, поэтому повтор после рестарта безопасен.
 */
export function startVotingLifecycle() {
  schedule('resolve expired votings', 'SELECT public.resolve_expired_votings()', MINUTE);
  schedule('calculate chart scores', 'SELECT public.calculate_chart_scores()', 5 * MINUTE);
  schedule('update voter ranks', 'SELECT public.update_voter_ranks()', DAY);
  schedule('process contest lifecycle', 'SELECT public.process_contest_lifecycle()', MINUTE, true);
}
