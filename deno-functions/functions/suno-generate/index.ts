import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { markTracksFailed, refundPendingGenerationLogs, SUNO_API_BASE } from "../../shared/suno.ts";
import { getSunoErrorMessage } from "./errors.ts";
import { cleanStyleForSuno } from "./styleUtils.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");

const handler = async (req: Request) => {
  let userId = "";
  let allTrackIds: string[] = [];
  let refundReason = "Ошибка запуска генерации";
  let refundDetails = "Генерация не была запущена из-за ошибки сервера. Средства возвращены на баланс.";
  let supabaseAdmin: ReturnType<typeof createClient> | null = null;

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );

    supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    userId = user.id;

    const body = await req.json();
    const trackId = body.trackId as string | undefined;
    const trackIds = body.trackIds as string[] | undefined;
    const prompt = body.prompt as string | undefined;
    const lyrics = body.lyrics as string | undefined;
    const style = body.style as string | undefined;
    const title = body.title as string | undefined;
    const instrumental = Boolean(body.instrumental);
    const audioReferenceUrl = body.audioReferenceUrl as string | undefined;
    const negativeTags = body.negativeTags as string | undefined;
    const vocalGender = body.vocalGender as string | undefined;
    const personaId = body.personaId as string | undefined;

    if (!trackId) {
      return new Response(
        JSON.stringify({ error: "Missing required field: trackId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    allTrackIds = Array.isArray(trackIds) && trackIds.length > 0 ? trackIds : [trackId];
    const cleanedStyle = cleanStyleForSuno(style || "");
    const hasLyrics = !!lyrics?.trim();
    const hasStyle = !!cleanedStyle.trim();
    const useCustomMode = hasLyrics || hasStyle;

    const { error: updateError } = await supabaseClient
      .from("tracks")
      .update({ status: "processing", error_message: null })
      .in("id", allTrackIds)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("Failed to update track status:", updateError);
    }

    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    const explicitCallbackUrl = Deno.env.get("SUNO_CALLBACK_URL");
    const baseCallbackUrl =
      explicitCallbackUrl || `${Deno.env.get("SUPABASE_URL")}/functions/v1/suno-callback`;
    const callBackUrl = callbackSecret
      ? `${baseCallbackUrl}${baseCallbackUrl.includes("?") ? "&" : "?"}secret=${encodeURIComponent(callbackSecret)}`
      : baseCallbackUrl;

    const STYLE_CHAR_LIMIT = 1000;
    const PROMPT_CHAR_LIMIT = 5000;
    const NON_CUSTOM_PROMPT_LIMIT = 500;

    const sunoPayload: Record<string, unknown> = {
      model: "V5",
      customMode: useCustomMode,
      instrumental,
      callBackUrl,
    };

    if (negativeTags?.trim()) {
      sunoPayload.negativeTags = negativeTags.trim();
    }

    if (vocalGender === "m" || vocalGender === "f") {
      sunoPayload.vocalGender = vocalGender;
    }

    if (personaId) {
      sunoPayload.personaId = personaId;
    }

    if (useCustomMode) {
      if (hasLyrics) {
        sunoPayload.prompt = lyrics!.slice(0, PROMPT_CHAR_LIMIT);
      } else if (!instrumental) {
        sunoPayload.customMode = false;
        sunoPayload.prompt = (prompt || cleanedStyle).slice(0, NON_CUSTOM_PROMPT_LIMIT);
      }

      let finalStyle = cleanedStyle || "pop";
      if (finalStyle.length > STYLE_CHAR_LIMIT) {
        const parts = finalStyle.split(", ");
        let truncated = "";
        for (const part of parts) {
          const nextValue = truncated ? `${truncated}, ${part}` : part;
          if (nextValue.length <= STYLE_CHAR_LIMIT) {
            truncated = nextValue;
          } else {
            break;
          }
        }
        finalStyle = truncated || finalStyle.slice(0, STYLE_CHAR_LIMIT);
      }

      sunoPayload.style = finalStyle;
      sunoPayload.title = (title || "Untitled").slice(0, 100);
    } else {
      sunoPayload.prompt = (prompt || "").slice(0, NON_CUSTOM_PROMPT_LIMIT);
    }

    let sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate`;
    if (audioReferenceUrl) {
      if (audioReferenceUrl.includes("localhost") || audioReferenceUrl.includes("127.0.0.1")) {
        return new Response(
          JSON.stringify({ error: "Генерация с аудио-референсом недоступна на localhost. Тестируйте эту функцию на https://aimuza.ru." }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate/upload-cover`;
      sunoPayload.uploadUrl = audioReferenceUrl;
    }

    if (!SUNO_API_KEY) {
      refundReason = "Генерация недоступна";
      refundDetails = "На сервере не настроен SUNO_API_KEY. Средства возвращены на баланс.";
      await markTracksFailed(supabaseAdmin, allTrackIds, refundReason, user.id);
      const refundResult = await refundPendingGenerationLogs(supabaseAdmin, {
        userId: user.id,
        trackIds: allTrackIds,
        reason: `Возврат за неудачный запуск генерации: ${refundReason}`,
        fullMessage: refundDetails,
      });

      return new Response(
        JSON.stringify({
          error: refundReason,
          details: refundDetails,
          refunded: refundResult.refundedAmount > 0,
          refundAmount: refundResult.refundedAmount,
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const sunoResponse = await fetch(sunoEndpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    if (!sunoResponse.ok || sunoData.code !== 200) {
      const rawErrorMessage = sunoData.msg || "Failed to start generation";
      const errorCode = sunoData.code || sunoResponse.status || 500;
      const errorInfo = getSunoErrorMessage(errorCode, rawErrorMessage);

      refundReason = errorInfo.short;
      refundDetails = errorInfo.full;

      await markTracksFailed(supabaseAdmin, allTrackIds, refundReason, user.id);
      const refundResult = await refundPendingGenerationLogs(supabaseAdmin, {
        userId: user.id,
        trackIds: allTrackIds,
        reason: `Возврат за неудачную генерацию: ${refundReason}`,
        fullMessage: refundDetails,
      });

      return new Response(
        JSON.stringify({
          error: refundReason,
          details: refundDetails,
          refunded: refundResult.refundedAmount > 0,
          refundAmount: refundResult.refundedAmount,
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const taskId =
      sunoData.data?.taskId || sunoData.data?.task_id || sunoData.taskId || sunoData.task_id;

    if (!taskId) {
      refundReason = "Suno не вернул taskId";
      refundDetails =
        "Сервис Suno не вернул идентификатор задачи. Генерация не может быть отслежена, поэтому средства возвращены.";

      await markTracksFailed(supabaseAdmin, allTrackIds, refundReason, user.id);
      const refundResult = await refundPendingGenerationLogs(supabaseAdmin, {
        userId: user.id,
        trackIds: allTrackIds,
        reason: `Возврат за генерацию без taskId: ${refundReason}`,
        fullMessage: refundDetails,
      });

      return new Response(
        JSON.stringify({
          error: refundReason,
          details: refundDetails,
          refunded: refundResult.refundedAmount > 0,
          refundAmount: refundResult.refundedAmount,
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: pairTracks, error: pairErr } = await supabaseAdmin
      .from("tracks")
      .select("id, title, description")
      .in("id", allTrackIds);

    if (pairErr) {
      console.error("Error fetching pair tracks:", pairErr);
    }

    const tracksToUpdate = pairTracks && pairTracks.length > 0
      ? pairTracks
      : [{ id: trackId, title: null, description: null }];

    for (const track of tracksToUpdate) {
      if (track.description?.includes("[task_id:")) continue;

      const updatedDescription = track.description
        ? `${track.description}\n\n[task_id: ${taskId}]`
        : `[task_id: ${taskId}]`;

      const { error } = await supabaseAdmin
        .from("tracks")
        .update({ description: updatedDescription })
        .eq("id", track.id);

      if (error) {
        console.error(`Failed to store task_id in track ${track.id}:`, error);
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        taskId,
        message: "Generation started successfully",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("Error in suno-generate:", error);

    if (supabaseAdmin && userId && allTrackIds.length > 0) {
      await markTracksFailed(supabaseAdmin, allTrackIds, refundReason, userId);
      await refundPendingGenerationLogs(supabaseAdmin, {
        userId,
        trackIds: allTrackIds,
        reason: `Возврат за внутреннюю ошибку генерации: ${refundReason}`,
        fullMessage: refundDetails,
      });
    }

    return new Response(
      JSON.stringify({ error: refundDetails }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
