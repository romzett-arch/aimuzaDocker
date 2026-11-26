import { pool } from '../db.js';

async function processContestLifecycle() {
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    await client.query("SELECT set_config('request.jwt.claim.role', 'service_role', true)");
    await client.query('SELECT public.process_contest_lifecycle()');
    await client.query('COMMIT');
  } catch (error) {
    await client?.query('ROLLBACK').catch(() => {});
    console.error('[Contest lifecycle] Processing failed:', error.message);
  } finally {
    client?.release();
  }
}

export function startContestLifecycle() {
  void processContestLifecycle();
  setInterval(processContestLifecycle, 60_000).unref();
}
