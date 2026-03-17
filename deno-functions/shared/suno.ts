import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const SUNO_API_BASE = "https://api.sunoapi.org";

export const SUNO_TERMINAL_FAILURES = new Set([
  "GENERATE_AUDIO_FAILED",
  "CREATE_TASK_FAILED",
  "CALLBACK_EXCEPTION",
  "SENSITIVE_WORD_ERROR",
  "FAILED",
  "ERROR",
]);

type TrackStatusClient = Pick<SupabaseClient, "from" | "rpc">;

export function normalizeSunoRecords(records: Array<Record<string, unknown>>) {
  return records.map((record) => {
    const audioUrls = [
      record.sourceAudioUrl, record.source_audio_url,
      record.audioUrl, record.audio_url,
      record.sourceStreamAudioUrl, record.source_stream_audio_url,
      record.streamAudioUrl, record.stream_audio_url,
    ].filter((value): value is string => typeof value === "string" && value.startsWith("http"));

    const imageUrls = [
      record.sourceImageUrl, record.source_image_url,
      record.imageUrl, record.image_url,
    ].filter((value): value is string => typeof value === "string" && value.startsWith("http"));

    return {
      id: record.id ? String(record.id) : null,
      duration: typeof record.duration === "number" ? record.duration : record.duration != null ? Number(record.duration) : null,
      audioUrl: audioUrls[0] || null,
      audioUrls,
      imageUrl: imageUrls[0] || null,
      imageUrls,
    };
  });
}

export async function markTracksFailed(
  supabase: TrackStatusClient,
  trackIds: string[],
  errorMessage: string,
  userId?: string,
) {
  const uniqueTrackIds = [...new Set(trackIds.filter(Boolean))];
  if (uniqueTrackIds.length === 0) return;

  let query = supabase
    .from("tracks")
    .update({
      status: "failed",
      error_message: errorMessage,
    })
    .in("id", uniqueTrackIds)
    .in("status", ["pending", "processing", "failed"]);

  if (userId) {
    query = query.eq("user_id", userId);
  }

  const { error } = await query;
  if (error) {
    console.error("[suno] Failed to mark tracks as failed:", error);
  }
}

export async function markGenerationLogsCompleted(
  supabase: TrackStatusClient,
  trackIds: string[],
) {
  const uniqueTrackIds = [...new Set(trackIds.filter(Boolean))];
  if (uniqueTrackIds.length === 0) return;

  const { error } = await supabase
    .from("generation_logs")
    .update({ status: "completed" })
    .in("track_id", uniqueTrackIds)
    .in("status", ["pending", "failed"]);

  if (error) {
    console.error("[suno] Failed to mark generation_logs as completed:", error);
  }
}

export async function refundPendingGenerationLogs(
  supabase: TrackStatusClient,
  params: {
    userId: string;
    trackIds: string[];
    reason: string;
    fullMessage?: string;
  },
) {
  const uniqueTrackIds = [...new Set(params.trackIds.filter(Boolean))];
  if (uniqueTrackIds.length === 0) {
    return { refundedAmount: 0, refundedTrackIds: [] as string[] };
  }

  const { data: logs, error: logsError } = await supabase
    .from("generation_logs")
    .select("track_id, cost_rub")
    .eq("user_id", params.userId)
    .in("track_id", uniqueTrackIds)
    .eq("status", "pending");

  if (logsError) {
    console.error("[suno] Failed to load generation_logs for refund:", logsError);
    return { refundedAmount: 0, refundedTrackIds: [] as string[] };
  }

  let refundedAmount = 0;
  const refundedTrackIds: string[] = [];

  for (const log of logs ?? []) {
    const amount = Number(log.cost_rub || 0);
    if (!log.track_id || amount <= 0) continue;

    const { error } = await supabase.rpc("refund_generation_failed", {
      p_user_id: params.userId,
      p_amount: amount,
      p_track_id: log.track_id,
      p_description: params.reason,
    });

    if (error) {
      console.error(`[suno] Refund failed for track ${log.track_id}:`, error);
      continue;
    }

    refundedAmount += amount;
    refundedTrackIds.push(log.track_id);
  }

  if (refundedTrackIds.length > 0) {
    const { error } = await supabase
      .from("generation_logs")
      .update({ status: "failed" })
      .eq("user_id", params.userId)
      .in("track_id", refundedTrackIds)
      .eq("status", "pending");

    if (error) {
      console.error("[suno] Failed to mark generation_logs as failed after refund:", error);
    }

    await supabase.from("notifications").insert({
      user_id: params.userId,
      type: "refund",
      title: `Ошибка: ${params.reason}`,
      message: `${params.fullMessage || params.reason}\n\nВам возвращено ${refundedAmount} ₽`,
      target_type: "track",
      target_id: refundedTrackIds[0],
    });
  }

  return { refundedAmount, refundedTrackIds };
}
