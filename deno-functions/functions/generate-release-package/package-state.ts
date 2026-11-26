import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

interface PackageDetails {
  requested_title: string;
  requested_performer_name: string | null;
  requested_author_name: string | null;
  requested_genre: string;
  requested_cover_id: string;
  requested_has_lyrics: boolean;
  requested_include_deposit: boolean;
  requested_move_to_my_releases: boolean | null;
}

export async function beginReleasePackage(
  supabase: SupabaseClient, trackId: string, owner: string, usePromo: boolean, details: PackageDetails,
): Promise<string> {
  const { data, error } = await supabase.rpc("begin_release_package", {
    p_user_id: owner, p_track_id: trackId, p_promo: usePromo, p_details: details,
  });
  if (error || typeof data !== "string") throw new Error(error?.message || "release_package_claim_failed");
  return data;
}

export async function finishReleasePackage(
  supabase: SupabaseClient, trackId: string, owner: string, lease: string,
  result: { status: "completed" | "failed" } & Record<string, string | null>,
) {
  const { data, error } = await supabase.from("release_packages")
    .update({ ...result, lease_id: null, lease_until: null, updated_at: new Date().toISOString() })
    .eq("track_id", trackId).eq("user_id", owner).eq("lease_id", lease)
    .select("id").maybeSingle();
  if (error || !data) throw new Error(error?.message || "release_package_lease_expired");
}
