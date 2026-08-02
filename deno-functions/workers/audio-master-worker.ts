import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createAndStorePlaybackMaster } from "../functions/suno-callback/master-audio.ts";

type AudioMasterJob = {
  id: string;
  track_id: string;
  source_audio_url: string;
  attempts: number;
};

const workerId = `audio-master-${crypto.randomUUID()}`;
const concurrency = Math.min(Math.max(Number(Deno.env.get("AUDIO_MASTER_CONCURRENCY")) || 4, 1), 16);
const maxAttempts = Math.min(Math.max(Number(Deno.env.get("AUDIO_MASTER_MAX_ATTEMPTS")) || 8, 1), 20);
const pollMs = Math.min(Math.max(Number(Deno.env.get("AUDIO_MASTER_POLL_MS")) || 1000, 250), 30_000);
const leaseSeconds = Math.min(Math.max(Number(Deno.env.get("AUDIO_MASTER_LEASE_SECONDS")) || 600, 60), 3600);

function retryDelaySeconds(attempt: number): number {
  return Math.min(900, 15 * 2 ** Math.max(0, attempt - 1));
}

async function markJobFailure(supabase: SupabaseClient, job: AudioMasterJob, error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  const exhausted = job.attempts >= maxAttempts;
  const runAfter = new Date(Date.now() + retryDelaySeconds(job.attempts) * 1000).toISOString();

  const { error: jobError } = await supabase
    .from("audio_master_jobs")
    .update({
      status: exhausted ? "failed" : "queued",
      run_after: runAfter,
      lease_until: null,
      locked_by: null,
      last_error: message.slice(0, 4000),
      updated_at: new Date().toISOString(),
    })
    .eq("id", job.id)
    .eq("locked_by", workerId);

  if (jobError) console.error(`[audio-master-worker] Could not release job ${job.id}:`, jobError);

  await supabase.from("tracks").update({
    processing_stage: exhausted ? "mastering_failed" : "mastering_queued",
    error_message: exhausted
      ? "Не удалось создать мастер −10 LUFS после повторных попыток. Оригинал сохранён."
      : "Оригинал сохранён. Мастер −10 LUFS будет создан повторно.",
  }).eq("id", job.track_id).is("master_audio_url", null);

  console.error(
    `[audio-master-worker] Job ${job.id} for track ${job.track_id} failed on attempt ${job.attempts}/${maxAttempts}:`,
    message,
  );
}

async function processJob(supabase: SupabaseClient, job: AudioMasterJob) {
  const startedAt = Date.now();
  console.log(`[audio-master-worker] Processing track ${job.track_id}, attempt ${job.attempts}`);

  try {
    await supabase.from("tracks").update({
      processing_stage: "mastering",
      processing_progress: 90,
      error_message: null,
    }).eq("id", job.track_id).is("master_audio_url", null);

    const master = await createAndStorePlaybackMaster(supabase, job.track_id, job.source_audio_url);
    const completedAt = new Date().toISOString();

    const { error: trackError } = await supabase.from("tracks").update({
      master_audio_url: master.url,
      normalized_audio_url: master.url,
      lufs_normalized: true,
      status: "completed",
      processing_stage: "completed",
      processing_progress: 100,
      processing_completed_at: completedAt,
      error_message: null,
    }).eq("id", job.track_id);
    if (trackError) throw new Error(`Could not complete track: ${trackError.message}`);

    await supabase.from("track_health_reports").upsert({
      track_id: job.track_id,
      normalized_audio_url: master.url,
      lufs_normalized: master.lufs,
      peak_db: master.peakDb,
      normalization_status: "completed",
      updated_at: completedAt,
    }, { onConflict: "track_id" });

    await supabase.from("generation_logs").update({ status: "completed" }).eq("track_id", job.track_id);

    const { error: completeError } = await supabase.from("audio_master_jobs").update({
      status: "completed",
      lease_until: null,
      locked_by: null,
      last_error: null,
      completed_at: completedAt,
      updated_at: completedAt,
    }).eq("id", job.id).eq("locked_by", workerId);
    if (completeError) throw new Error(`Could not complete queue job: ${completeError.message}`);

    console.log(`[audio-master-worker] Completed track ${job.track_id} in ${Date.now() - startedAt}ms`);
  } catch (error) {
    await markJobFailure(supabase, job, error);
  }
}

export function startAudioMasterWorker() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !serviceRoleKey) {
    console.warn("[audio-master-worker] Disabled: Supabase service credentials are missing");
    return;
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const active = new Set<Promise<void>>();
  let claiming = false;

  const tick = async () => {
    if (claiming || active.size >= concurrency) return;
    claiming = true;
    try {
      const { data, error } = await supabase.rpc("claim_audio_master_jobs", {
        p_worker_id: workerId,
        p_limit: concurrency - active.size,
        p_lease_seconds: leaseSeconds,
      });
      if (error) {
        console.error("[audio-master-worker] Claim failed:", error);
        return;
      }

      for (const job of (data || []) as AudioMasterJob[]) {
        let task: Promise<void>;
        task = processJob(supabase, job).finally(() => active.delete(task));
        active.add(task);
      }
    } finally {
      claiming = false;
    }
  };

  console.log(`[audio-master-worker] Started as ${workerId}, concurrency=${concurrency}`);
  void tick();
  setInterval(() => void tick(), pollMs);
}
