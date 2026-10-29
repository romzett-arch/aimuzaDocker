import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// suno_id is a legacy field and remains null for successful modern tasks.
// Reapply these guards on UPDATE so a concurrently started task cannot be failed.
function abandonedQuery(client: SupabaseClient, userId: string, cutoff: string, message?: string) {
  const table = client.from("tracks");
  const query = message === undefined
    ? table.select("id, description")
    : table.update({ status: "failed", error_message: message });
  return query
    .eq("user_id", userId)
    .in("status", ["pending", "processing"])
    .lt("created_at", cutoff)
    .is("suno_id", null)
    .is("provider_task_id", null)
    .is("suno_audio_id", null)
    .is("audio_url", null)
    .or("source_type.neq.uploaded,source_type.is.null");
}

export async function failAbandonedGenerations(
  client: SupabaseClient, userId: string, cutoff: string, message: string,
): Promise<string[]> {
  // Legacy tasks may only have a description marker, without provider_task_id.
  const { data: candidates, error: readError } = await abandonedQuery(client, userId, cutoff);
  if (readError) throw readError;
  const ids = (candidates || [])
    .filter(track => !/\[task_id:\s*[^\]\s][^\]]*\]/i.test(track.description || ""))
    .map(track => track.id);
  if (!ids.length) return [];

  const { data, error } = await abandonedQuery(client, userId, cutoff, message)
    .in("id", ids).select("id");
  if (error) throw error;
  return (data || []).map(track => track.id);
}
