import { pool } from '../db.js';

export function startSunoOrderRecovery() {
  let running = false;
  const recover = async () => {
    if (running) return;
    running = true;
    try {
      await pool.query('SELECT public.expire_unclaimed_suno_orders()');
      await pool.query('SELECT public.expire_unconfirmed_suno_orders()');
      await pool.query('SELECT public.expire_release_packages()');
    } catch (error) {
      console.error('[suno-order-recovery]', error.message);
    } finally {
      running = false;
    }
  };
  setTimeout(recover, 15_000).unref();
  setInterval(recover, 60_000).unref();
}
