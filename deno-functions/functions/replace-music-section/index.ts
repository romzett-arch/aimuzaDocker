import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const API_BASE = "https://api.sunoapi.org";
const SERVICE_NAME = "replace_music_section";
const MIN_INTERVAL_SECONDS = 10;

class RequestError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function cleanString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function roundTime(value: number): number {
  return Math.round(value * 100) / 100;
}

function sourceTaskId(description: string | null): string | null {
  return description?.match(/\[task_id:\s*([^\]]+)\]/i)?.[1]?.trim() || null;
}

function publicAudioUrl(value: string, baseUrl: string): string {
  try {
    return new URL(value, `${baseUrl.replace(/\/$/, "")}/`).toString();
  } catch {
    return value;
  }
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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const startedAt = Date.now();
  const requestId = crypto.randomUUID();
  const resultTrackIds: string[] = [];
  let userId: string | null = null;
  let generationLogId: string | null = null;
  let debitedAmount = 0;
  let adminClient: ReturnType<typeof createClient<any>> | null = null;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) throw new RequestError("Необходима авторизация", 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    adminClient = createClient<any>(supabaseUrl, serviceRoleKey);
    const { data: { user }, error: authError } = await adminClient.auth.getUser(authHeader.slice(7));
    if (authError || !user) throw new RequestError("Неверный токен авторизации", 401);
    userId = user.id;

    const body = await req.json();
    const trackId = cleanString(body?.track_id);
    const replacementMode = cleanString(body?.replacement_mode) || "lyrics";
    const title = cleanString(body?.title);
    const prompt = cleanString(body?.prompt);
    const fullLyrics = cleanString(body?.full_lyrics);
    const tags = cleanString(body?.tags);
    const negativeTags = cleanString(body?.negative_tags);
    const infillStartS = roundTime(Number(body?.infill_start_s));
    const infillEndS = roundTime(Number(body?.infill_end_s));

    if (!trackId) throw new RequestError("Выберите исходный трек", 422);
    if (!['lyrics', 'instrumental'].includes(replacementMode)) throw new RequestError("Неверный тип замены", 422);
    if (!title || title.length > 100) throw new RequestError("Название обязательно, максимум 100 символов", 422);
    if (!prompt || prompt.length > 5000) throw new RequestError("Новый текст фрагмента обязателен, максимум 5000 символов", 422);
    if (!fullLyrics || fullLyrics.length > 10000) throw new RequestError("Полный итоговый текст обязателен", 422);
    if (!tags || tags.length > 1000) throw new RequestError("Укажите стиль музыки, максимум 1000 символов", 422);
    if (negativeTags.length > 1000) throw new RequestError("Исключения — максимум 1000 символов", 422);
    if (!Number.isFinite(infillStartS) || !Number.isFinite(infillEndS) || infillStartS < 0 || infillEndS <= infillStartS) {
      throw new RequestError("Неверный временной диапазон", 422);
    }
    if (roundTime(infillEndS - infillStartS) < MIN_INTERVAL_SECONDS) {
      throw new RequestError("Заменяемый фрагмент должен быть не короче 10 секунд", 422);
    }

    const { data: track, error: trackError } = await adminClient
      .from("tracks")
      .select("id,user_id,title,description,lyrics,audio_url,cover_url,duration,genre_id,model_id,vocal_type_id,template_id,artist_style_id,is_public,source_type,suno_audio_id,performer_name,music_author,lyrics_author")
      .eq("id", trackId)
      .maybeSingle();
    if (trackError || !track) throw new RequestError("Трек не найден", 404);
    if (track.user_id !== userId) throw new RequestError("Нет доступа к треку", 403);
    if (!track.audio_url || Number(track.duration || 0) < 20) {
      throw new RequestError("Функция доступна для готовых треков длиннее 20 секунд", 422);
    }

    const trackDuration = Number(track.duration);
    const selectedDuration = roundTime(infillEndS - infillStartS);
    if (infillEndS > trackDuration + 0.01) throw new RequestError("Конец фрагмента выходит за длительность трека", 422);
    if (selectedDuration > roundTime(trackDuration * 0.5) + 0.01) {
      throw new RequestError("За один раз можно заменить не более 50% трека", 422);
    }

    const { data: debitRows, error: debitError } = await adminClient.rpc("debit_addon_service", {
      p_user_id: userId,
      p_service_name: SERVICE_NAME,
      p_description: `Замена фрагмента: ${track.title}`,
      p_metadata: { request_id: requestId, service_name: SERVICE_NAME, source_track_id: trackId },
    });
    if (debitError) {
      const insufficient = debitError.message?.includes("Insufficient balance");
      throw new RequestError(insufficient ? "Недостаточно средств на балансе" : "Услуга временно недоступна", insufficient ? 402 : 503);
    }
    const debit = debitRows?.[0];
    debitedAmount = Number(debit?.amount_debited || 0);

    const pendingTracks = [0, 1].map((variant) => ({
      user_id: userId,
      title,
      description: `${tags}\n\n[generation_variant: ${variant}]`,
      lyrics: fullLyrics,
      audio_url: null,
      cover_url: track.cover_url,
      duration: track.duration,
      genre_id: track.genre_id,
      model_id: track.model_id,
      vocal_type_id: track.vocal_type_id,
      template_id: track.template_id,
      artist_style_id: track.artist_style_id,
      is_public: track.is_public,
      source_type: "generated",
      status: "processing",
      audio_reference_url: track.audio_url,
      performer_name: track.performer_name,
      music_author: track.music_author,
      lyrics_author: track.lyrics_author,
    }));
    const { data: createdTracks, error: createError } = await adminClient.from("tracks").insert(pendingTracks).select("id");
    if (createError || !createdTracks?.length) throw new Error("Не удалось создать результирующие треки");
    resultTrackIds.push(...createdTracks.map((item: { id: string }) => item.id));

    const originalTaskId = sourceTaskId(track.description);
    const sourceMode = originalTaskId && track.suno_audio_id ? "generated" : "uploaded";
    const generationParams = {
      source_track_id: trackId,
      source_mode: sourceMode,
      replacement_mode: replacementMode,
      infill_start_s: infillStartS,
      infill_end_s: infillEndS,
      selected_duration_s: selectedDuration,
      prompt,
      full_lyrics: fullLyrics,
      tags,
      negative_tags: negativeTags || null,
      title,
    };
    const { data: logRow, error: logError } = await adminClient.from("generation_logs").insert({
      user_id: userId,
      track_id: resultTrackIds[0],
      request_id: requestId,
      service_id: debit?.service_id || null,
      service_name: SERVICE_NAME,
      provider: debit?.provider || "sunoapi",
      provider_operation: debit?.provider_operation || "replace_section",
      provider_model: "V6",
      model: "V6",
      prompt,
      status: "processing",
      cost_rub: debitedAmount,
      sale_price_rub: debitedAmount,
      base_cost_credits: Number(debit?.base_cost_credits || 0),
      generation_params: generationParams,
      metadata: { result_track_ids: resultTrackIds },
    }).select("id").single();
    if (logError || !logRow?.id) throw new Error("Не удалось зафиксировать платную операцию");
    const createdLogId = String(logRow.id);
    generationLogId = createdLogId;

    const apiKey = Deno.env.get("SUNO_API_KEY");
    if (!apiKey) throw new Error("Музыкальный AI временно недоступен");
    const publicBaseUrl = (Deno.env.get("BASE_URL") || "https://aimuza.ru").replace(/\/$/, "");
    const callbackToken = await signCallback(createdLogId, serviceRoleKey);
    const callBackUrl = `${publicBaseUrl}/functions/v1/replace-music-section-callback?log_id=${encodeURIComponent(createdLogId)}&token=${encodeURIComponent(callbackToken)}`;
    const providerPrompt = replacementMode === "instrumental" ? `[Instrumental]\n${prompt}` : prompt;
    const providerPayload: Record<string, unknown> = {
      prompt: providerPrompt,
      tags,
      title,
      infillStartS,
      infillEndS,
      fullLyrics,
      callBackUrl,
    };
    if (replacementMode === "instrumental") {
      providerPayload.negativeTags = "vocals, singing, spoken word";
    } else if (negativeTags) {
      providerPayload.negativeTags = negativeTags;
    }
    if (sourceMode === "generated") {
      providerPayload.taskId = originalTaskId;
      providerPayload.audioId = track.suno_audio_id;
    } else {
      providerPayload.uploadUrl = publicAudioUrl(track.audio_url, publicBaseUrl);
      providerPayload.model = "V6";
    }

    const providerResponse = await fetch(`${API_BASE}/api/v1/generate/replace-section`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(providerPayload),
    });
    const providerResult = await providerResponse.json().catch(() => ({}));
    const providerTaskId = providerResult?.data?.taskId;
    if (!providerResponse.ok || providerResult?.code !== 200 || !providerTaskId) {
      throw new Error(cleanString(providerResult?.msg) || "Не удалось запустить замену фрагмента");
    }

    await adminClient.from("generation_logs").update({
      metadata: { result_track_ids: resultTrackIds, provider_task_id: providerTaskId },
    }).eq("id", createdLogId);
    await adminClient.from("tracks").update({
      description: `${tags}\n\n[task_id: ${providerTaskId}]`,
    }).in("id", resultTrackIds);

    return jsonResponse({
      success: true,
      status: "processing",
      task_id: providerTaskId,
      track_ids: resultTrackIds,
      amount_debited: debitedAmount,
    }, 202);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Не удалось заменить фрагмент";
    const status = error instanceof RequestError ? error.status : 500;
    console.error("replace-music-section failed:", error);
    let refunded = false;
    if (adminClient && userId && debitedAmount > 0) {
      const { error: refundError } = await adminClient.rpc("refund_addon_service", {
        p_user_id: userId,
        p_amount: debitedAmount,
        p_description: "Возврат за неуспешную замену фрагмента",
        p_metadata: { request_id: requestId, service_name: SERVICE_NAME },
      });
      refunded = !refundError;
      if (refundError) console.error("replace section refund failed:", refundError);
    }
    if (adminClient && resultTrackIds.length) {
      await adminClient.from("tracks").update({ status: "failed", error_message: message }).in("id", resultTrackIds);
    }
    if (adminClient && generationLogId) {
      await adminClient.from("generation_logs").update({
        status: "failed",
        error_message: message,
        refund_rub: refunded ? debitedAmount : 0,
        duration_ms: Date.now() - startedAt,
      }).eq("id", generationLogId);
    }
    return jsonResponse({ error: message, refunded }, status);
  }
});
