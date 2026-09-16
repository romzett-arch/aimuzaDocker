import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SERVICE_NAME = "replace_music_section";

function response(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

async function signCallback(logId: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(logId));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function safeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index += 1) mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return mismatch === 0;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return response({ code: 405, msg: "Method not allowed" }, 405);

  let logId = "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const supabase = createClient(Deno.env.get("SUPABASE_URL") || "", serviceRoleKey);

  try {
    const url = new URL(req.url);
    logId = url.searchParams.get("log_id") || "";
    const token = url.searchParams.get("token") || "";
    if (!logId || !token) return response({ code: 401, msg: "Unauthorized" }, 401);
    const expectedToken = await signCallback(logId, serviceRoleKey);
    if (!safeEqual(expectedToken, token)) return response({ code: 401, msg: "Unauthorized" }, 401);

    const { data: log, error: logError } = await supabase.from("generation_logs")
      .select("id,user_id,track_id,status,sale_price_rub,refund_rub,metadata,generation_params,created_at")
      .eq("id", logId)
      .eq("service_name", SERVICE_NAME)
      .maybeSingle();
    if (logError || !log) return response({ code: 404, msg: "Operation not found" }, 404);

    const metadata = asRecord(log.metadata);
    if (["completed", "failed", "refunded"].includes(log.status)) return response({ code: 200, msg: "success" });

    const payload = await req.json();
    const data = asRecord(payload?.data);
    const callbackType = asString(data.callbackType).toLowerCase();
    const providerTaskId = asString(data.task_id) || asString(data.taskId);
    const expectedTaskId = asString(metadata.provider_task_id);
    if (expectedTaskId && providerTaskId && expectedTaskId !== providerTaskId) {
      return response({ code: 409, msg: "Task mismatch" }, 409);
    }

    const isSuccess = Number(payload?.code) === 200 && callbackType === "complete";
    const isFailure = Number(payload?.code) !== 200 || callbackType === "error" || callbackType === "failed";
    if (!isSuccess && !isFailure) return response({ code: 200, msg: "ignored" });

    const resultTrackIds = Array.isArray(metadata.result_track_ids)
      ? metadata.result_track_ids.filter((value): value is string => typeof value === "string")
      : [];
    const generationParams = asRecord(log.generation_params);

    if (isFailure) {
      const { data: claimed } = await supabase.from("generation_logs").update({ status: "refunding" })
        .eq("id", logId).in("status", ["pending", "processing"]).select("id").maybeSingle();
      if (!claimed) return response({ code: 200, msg: "success" });

      const errorMessage = asString(payload?.msg) || asString(data.error) || "Не удалось заменить фрагмент";
      const refundAmount = Number(log.sale_price_rub || 0);
      let refunded = Number(log.refund_rub || 0) > 0;
      if (!refunded && refundAmount > 0) {
        const { error: refundError } = await supabase.rpc("refund_addon_service", {
          p_user_id: log.user_id,
          p_amount: Math.round(refundAmount),
          p_description: "Возврат за неуспешную замену фрагмента",
          p_metadata: { generation_log_id: logId, service_name: SERVICE_NAME, provider_task_id: providerTaskId },
        });
        refunded = !refundError;
        if (refundError) console.error("replace callback refund failed:", refundError);
      }
      if (resultTrackIds.length) {
        await supabase.from("tracks").update({ status: "failed", error_message: errorMessage }).in("id", resultTrackIds);
      }
      await supabase.from("generation_logs").update({
        status: "failed",
        error_message: errorMessage,
        refund_rub: refunded ? refundAmount : 0,
        duration_ms: Date.now() - new Date(log.created_at).getTime(),
        metadata: { ...metadata, provider_task_id: providerTaskId || expectedTaskId, callback_code: payload?.code },
      }).eq("id", logId);
      await supabase.from("notifications").insert({
        user_id: log.user_id,
        type: "generation_failed",
        title: "Не удалось заменить фрагмент",
        message: refunded ? "Стоимость услуги возвращена на баланс" : errorMessage,
        target_type: "track",
        target_id: resultTrackIds[0] || log.track_id,
      });
      return response({ code: 200, msg: "success" });
    }

    const { data: claimed } = await supabase.from("generation_logs").update({ status: "finalizing" })
      .eq("id", logId).in("status", ["pending", "processing"]).select("id").maybeSingle();
    if (!claimed) return response({ code: 200, msg: "success" });

    const musicItems = Array.isArray(data.data) ? data.data.map(asRecord) : [];
    if (!musicItems.length) throw new Error("Provider returned no replacement audio");
    const completedTrackIds: string[] = [];
    for (let index = 0; index < resultTrackIds.length; index += 1) {
      const trackId = resultTrackIds[index];
      const item = musicItems[index];
      if (!item) {
        await supabase.from("tracks").update({
          status: "failed",
          error_message: "Второй вариант не был возвращён",
        }).eq("id", trackId);
        continue;
      }
      const audioUrl = asString(item.audio_url) || asString(item.stream_audio_url);
      if (!audioUrl) throw new Error("Replacement result has no audio URL");
      const itemTags = asString(item.tags) || asString(generationParams.tags);
      const taskIdMarker = providerTaskId || expectedTaskId;
      const description = [itemTags, taskIdMarker ? `[task_id: ${taskIdMarker}]` : "", `[generation_variant: ${index}]`]
        .filter(Boolean).join("\n\n");
      const trackUpdate: Record<string, unknown> = {
        title: asString(item.title) || asString(generationParams.title) || "Новая версия",
        description,
        lyrics: asString(generationParams.full_lyrics) || null,
        audio_url: audioUrl,
        suno_audio_id: asString(item.id) || null,
        status: "completed",
        error_message: null,
        processing_progress: 100,
        processing_stage: "completed",
        processing_completed_at: new Date().toISOString(),
      };
      if (asString(item.image_url)) trackUpdate.cover_url = asString(item.image_url);
      if (Number(item.duration || 0) > 0) trackUpdate.duration = Math.round(Number(item.duration));
      const { error: updateError } = await supabase.from("tracks").update(trackUpdate).eq("id", trackId);
      if (updateError) throw updateError;
      completedTrackIds.push(trackId);
    }

    await supabase.from("generation_logs").update({
      status: "completed",
      error_message: null,
      duration_ms: Date.now() - new Date(log.created_at).getTime(),
      metadata: {
        ...metadata,
        provider_task_id: providerTaskId || expectedTaskId,
        result_track_ids: resultTrackIds,
        completed_track_ids: completedTrackIds,
        result_audio_ids: musicItems.map((item) => asString(item.id)).filter(Boolean),
      },
    }).eq("id", logId);
    await supabase.from("notifications").insert({
      user_id: log.user_id,
      type: "generation_completed",
      title: "Новые версии готовы",
      message: `Фрагмент ${Number(generationParams.infill_start_s || 0).toFixed(2)}–${Number(generationParams.infill_end_s || 0).toFixed(2)} с успешно заменён`,
      target_type: "track",
      target_id: completedTrackIds[0] || log.track_id,
    });
    return response({ code: 200, msg: "success" });
  } catch (error: unknown) {
    console.error("replace-music-section-callback failed:", error);
    if (logId) {
      await supabase.from("generation_logs").update({
        status: "processing",
        error_message: error instanceof Error ? `callback: ${error.message}` : "callback processing failed",
      }).eq("id", logId).eq("status", "finalizing");
    }
    return response({ code: 500, msg: "Callback processing failed" }, 500);
  }
});
