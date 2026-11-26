import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { generateLyricsCertificate } from "./certificate.ts";
import { submitToOpenTimestamps } from "./services.ts";

interface ArtifactJob {
  lease: string;
  evidence_id: string;
  content_hash: string;
  deposited_at: string;
  signature: string;
}

export async function prepareLyricsArtifacts(supabase: SupabaseClient, id: string, userId: string) {
  const { data, error } = await supabase.rpc("claim_lyrics_deposit_artifacts", {
    p_deposit_id: id, p_user_id: userId,
  });
  if (error) throw error;
  if (!data) return null;
  const job = data as ArtifactJob;
  const proof = await submitToOpenTimestamps(job.content_hash);
  const certificateUrl = await generateLyricsCertificate(
    supabase, {}, job.content_hash, job.evidence_id, new Date(job.deposited_at).toISOString(),
    job.signature, "pending_external",
  );
  const { data: saved, error: saveError } = await supabase.from("lyrics_deposits")
    .update({
      certificate_url: certificateUrl,
      external_id: proof.id,
      external_proof: proof.proofBase64,
      artifacts_pending: false,
      artifact_lease_id: null,
      artifact_lease_until: null,
    })
    .eq("id", id).eq("user_id", userId).eq("artifact_lease_id", job.lease)
    .select("id").maybeSingle();
  if (saveError) throw saveError;
  return saved ? certificateUrl : null;
}

export async function recoverLyricsArtifacts(supabase: SupabaseClient) {
  const { data, error } = await supabase.from("lyrics_deposits")
    .select("id, user_id").eq("artifacts_pending", true)
    .or(`artifact_lease_until.is.null,artifact_lease_until.lte.${new Date().toISOString()}`)
    .order("created_at").limit(20);
  if (error) throw error;
  for (const deposit of data || []) {
    try {
      await prepareLyricsArtifacts(supabase, deposit.id, deposit.user_id);
    } catch (error) {
      console.warn(`[lyrics-deposit] artifacts pending for ${deposit.id}`, error);
    }
  }
}
