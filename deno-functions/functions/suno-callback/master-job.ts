import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export async function enqueuePlaybackMaster(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  sourceAudioUrl: string,
): Promise<void> {
  const { error } = await supabaseAdmin.rpc("enqueue_audio_master_job", {
    p_track_id: trackId,
    p_source_audio_url: sourceAudioUrl,
  });

  if (error) {
    throw new Error(`Could not enqueue playback master for ${trackId}: ${error.message}`);
  }
}

export async function claimSunoOriginalIngest(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  sunoAudioId: string | null,
): Promise<boolean> {
  const { data, error } = await supabaseAdmin.rpc("claim_track_audio_ingest", {
    p_track_id: trackId,
    p_suno_audio_id: sunoAudioId,
  });
  if (error) throw new Error(`Could not claim Suno original ingest for ${trackId}: ${error.message}`);
  return data === true;
}
