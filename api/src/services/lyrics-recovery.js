import { pool } from '../db.js';

let running = false;
export async function recoverPendingLyrics() {
  if (running || !process.env.DENO_FUNCTIONS_URL) return;
  running = true;
  try {
    const { rows } = await pool.query(`UPDATE public.lyrics_generation_jobs SET last_polled_at=now()
      WHERE id IN (SELECT id FROM public.lyrics_generation_jobs WHERE status='pending' AND provider_task_id IS NOT NULL
      ORDER BY last_polled_at NULLS FIRST LIMIT 10 FOR UPDATE SKIP LOCKED)
      RETURNING id,callback_token`);
    await Promise.allSettled(rows.map(async job => {
      const response = await fetch(`${process.env.DENO_FUNCTIONS_URL}/lyrics-callback?job=${job.id}&token=${job.callback_token}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) console.error('[lyrics recovery] retry required', job.id, response.status);
    }));
  } catch (error) {
    console.error('[lyrics recovery]', error.message);
  } finally { running = false; }
}

export function startLyricsRecovery() {
  void recoverPendingLyrics();
  setInterval(() => void recoverPendingLyrics(), 30000).unref();
}
