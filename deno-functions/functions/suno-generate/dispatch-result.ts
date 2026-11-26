import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getSunoErrorMessage } from "./errors.ts";

export async function rejectSunoGeneration(
  client: SupabaseClient, userId: string, trackId: string, allTrackIds: string[],
  errorCode: number, providerMessage: string | undefined, corsHeaders: Record<string, string>,
) {
  const rawErrorMessage = providerMessage || "Failed to start generation";

  const errorInfo = getSunoErrorMessage(errorCode, rawErrorMessage);
  const russianErrorMessage = errorInfo.short;

  console.error(`Suno API error (${errorCode}): ${rawErrorMessage} -> ${russianErrorMessage}`);

  const { data, error } = await client.rpc("fail_suno_generation", {
    p_user_id: userId, p_track_ids: allTrackIds, p_error: russianErrorMessage,
  });
  if (error) throw error;
  const totalRefund = Number(data ?? 0);

  if (totalRefund > 0) {
    await client
      .from("notifications")
      .insert({
        user_id: userId,
        type: "refund",
        title: `Ошибка: ${russianErrorMessage}`,
        message: `${errorInfo.full}\n\nВам возвращено ${totalRefund} ₽`,
        target_type: "track",
        target_id: trackId,
      });
  }

  return new Response(
    JSON.stringify({
      error: russianErrorMessage,
      details: errorInfo.full,
      refunded: totalRefund > 0,
      refundAmount: totalRefund
    }),
    { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}

export async function saveSunoTask(
  client: SupabaseClient, userId: string, allTrackIds: string[], taskId: string,
) {
  const { data, error } = await client.rpc("register_suno_generation_task", {
    p_user_id: userId, p_track_ids: allTrackIds, p_task_id: taskId,
  });
  if (error || data !== true) throw new Error(error?.message || "Could not register Suno task");
}
