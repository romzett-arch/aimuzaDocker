import type { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

type ReleasePackageStatus = "processing" | "completed" | "failed";

interface ReleasePackageRow {
  id: string;
  track_id: string;
  user_id: string;
  status: ReleasePackageStatus;
  zip_url: string | null;
  mp3_url: string | null;
  wav_url: string | null;
  cover_url: string | null;
  genre_txt_url: string | null;
  certificate_url: string | null;
  certificate_pdf_url: string | null;
  blockchain_proof_url: string | null;
  requested_title: string | null;
  requested_performer_name: string | null;
  requested_author_name: string | null;
  requested_genre: string | null;
  requested_cover_id: string | null;
  requested_has_lyrics: boolean | null;
  requested_include_deposit: boolean | null;
  requested_move_to_my_releases: boolean | null;
  error_message: string | null;
}

interface ExistingReleasePackageState {
  id: string;
  requested_title: string | null;
  requested_performer_name: string | null;
  requested_author_name: string | null;
  requested_genre: string | null;
  requested_cover_id: string | null;
  requested_has_lyrics: boolean | null;
  requested_include_deposit: boolean | null;
  requested_move_to_my_releases: boolean | null;
}

export async function upsertReleasePackage(
  supabase: ReturnType<typeof createClient>,
  trackId: string,
  userId: string,
  updates: Partial<ReleasePackageRow> & { status: ReleasePackageStatus },
): Promise<void> {
  const now = new Date().toISOString();
  const { data: existing, error: selectError } = await supabase
    .from("release_packages")
    .select("id, requested_title, requested_performer_name, requested_author_name, requested_genre, requested_cover_id, requested_has_lyrics, requested_include_deposit, requested_move_to_my_releases")
    .eq("track_id", trackId)
    .maybeSingle<ExistingReleasePackageState>();

  if (selectError) {
    throw new Error(`release_package_lookup_failed:${selectError.message}`);
  }

  const payload = {
    user_id: userId,
    status: updates.status,
    zip_url: updates.zip_url ?? null,
    mp3_url: updates.mp3_url ?? null,
    wav_url: updates.wav_url ?? null,
    cover_url: updates.cover_url ?? null,
    genre_txt_url: updates.genre_txt_url ?? null,
    certificate_url: updates.certificate_url ?? null,
    certificate_pdf_url: updates.certificate_pdf_url ?? null,
    blockchain_proof_url: updates.blockchain_proof_url ?? null,
    requested_title: updates.requested_title ?? existing?.requested_title ?? null,
    requested_performer_name: updates.requested_performer_name ?? existing?.requested_performer_name ?? null,
    requested_author_name: updates.requested_author_name ?? existing?.requested_author_name ?? null,
    requested_genre: updates.requested_genre ?? existing?.requested_genre ?? null,
    requested_cover_id: updates.requested_cover_id ?? existing?.requested_cover_id ?? null,
    requested_has_lyrics: updates.requested_has_lyrics ?? existing?.requested_has_lyrics ?? null,
    requested_include_deposit: updates.requested_include_deposit ?? existing?.requested_include_deposit ?? null,
    requested_move_to_my_releases: updates.requested_move_to_my_releases ?? existing?.requested_move_to_my_releases ?? false,
    error_message: updates.error_message ?? null,
    updated_at: now,
  };

  if (existing?.id) {
    const { error: updateError } = await supabase
      .from("release_packages")
      .update(payload)
      .eq("id", existing.id);

    if (updateError) {
      throw new Error(`release_package_update_failed:${updateError.message}`);
    }

    return;
  }

  const { error: insertError } = await supabase
    .from("release_packages")
    .insert({
      id: crypto.randomUUID(),
      track_id: trackId,
      created_at: now,
      ...payload,
    });

  if (insertError) {
    throw new Error(`release_package_insert_failed:${insertError.message}`);
  }
}
