import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getSunoErrorMessage } from "./errors.ts";
import { cleanStyleForSuno } from "./styleUtils.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://api.sunoapi.org";

const SUNO_MODEL = "V6";
const CUSTOM_PROMPT_LIMIT = 5000;
const STYLE_CHAR_LIMIT = 1000;
const TITLE_CHAR_LIMIT = 100;
const STANDARD_PROMPT_LIMIT = 3000;
const UPLOAD_COVER_PROMPT_LIMIT = 500;
const NEGATIVE_TAGS_LIMIT = 1000;

function validationError(message: string, field: string) {
  return new Response(
    JSON.stringify({ error: "Некорректные параметры генерации", details: message, field }),
    { status: 422, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
}

function parseOptionalWeight(value: unknown, field: string): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    throw new Error(`${field}: укажите число от 0 до 1`);
  }
  if (Math.abs(Math.round(parsed * 100) - parsed * 100) > 1e-8) {
    throw new Error(`${field}: допускается не более двух знаков после запятой`);
  }
  return parsed;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const {
      trackId,
      trackIds,
      customMode,
      prompt,
      lyrics,
      style,
      title,
      instrumental,
      audioReferenceUrl,
      negativeTags,
      vocalGender,
      duration,
      personaId,
      personaModel,
      styleWeight,
      weirdnessConstraint,
      audioWeight,
    } = await req.json();

    if (!trackId) {
      return new Response(
        JSON.stringify({ error: "Missing required field: trackId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const allTrackIds: string[] = Array.isArray(trackIds) && trackIds.length > 0 ? trackIds : [trackId];

    console.log(`Starting generation for tracks [${allTrackIds.join(", ")}] by user ${user.id}`);
    console.log(`Original prompt: ${prompt}`);
    console.log(`Original style: ${style}`);
    console.log(`Instrumental: ${instrumental}`);
    console.log(`Audio reference URL: ${audioReferenceUrl || 'none'}`);
    console.log(`Negative tags: ${negativeTags || 'none'}`);
    console.log(`Vocal gender: ${vocalGender || 'none'}`);
    console.log(`Persona ID: ${personaId || 'none'}`);
    console.log(`Model: ${SUNO_MODEL} (fixed)`);

    const cleanedStyle = cleanStyleForSuno(style || "");
    console.log(`Cleaned style: ${cleanedStyle}`);

    const cleanPrompt = typeof prompt === "string" ? prompt.trim() : "";
    const cleanLyrics = typeof lyrics === "string" ? lyrics.trim() : "";
    const cleanTitle = typeof title === "string" ? title.trim() : "";
    const cleanNegativeTags = typeof negativeTags === "string" ? negativeTags.trim() : "";
    const isCustomMode = customMode === true;
    const isInstrumental = instrumental === true;

    if (typeof customMode !== "boolean") return validationError("Режим генерации не указан", "customMode");
    if (cleanNegativeTags.length > NEGATIVE_TAGS_LIMIT) return validationError(`Максимум ${NEGATIVE_TAGS_LIMIT} символов`, "negativeTags");
    if (vocalGender !== undefined && vocalGender !== null && vocalGender !== "" && vocalGender !== "m" && vocalGender !== "f") {
      return validationError("Допустимы только m или f", "vocalGender");
    }

    let parsedDuration: number | undefined;
    if (duration !== undefined && duration !== null && duration !== "") {
      parsedDuration = Number(duration);
      if (!Number.isInteger(parsedDuration) || parsedDuration < 10 || parsedDuration > 360) {
        return validationError("Укажите целое число от 10 до 360 секунд", "duration");
      }
      if (!isCustomMode) return validationError("Длительность доступна только в режиме «Про»", "duration");
    }

    if (personaModel !== undefined && personaModel !== null && personaModel !== "" && personaModel !== "style_persona" && personaModel !== "voice_persona") {
      return validationError("Допустимы style_persona или voice_persona", "personaModel");
    }
    if (personaId && !isCustomMode) return validationError("Persona доступна только в режиме «Про»", "personaId");

    let parsedStyleWeight: number | undefined;
    let parsedWeirdness: number | undefined;
    let parsedAudioWeight: number | undefined;
    try {
      parsedStyleWeight = parseOptionalWeight(styleWeight, "styleWeight");
      parsedWeirdness = parseOptionalWeight(weirdnessConstraint, "weirdnessConstraint");
      parsedAudioWeight = parseOptionalWeight(audioWeight, "audioWeight");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Некорректный вес";
      return validationError(message, message.split(":")[0]);
    }

    if (isCustomMode) {
      if (!cleanedStyle) return validationError("Укажите стиль и аранжировку", "style");
      if (cleanedStyle.length > STYLE_CHAR_LIMIT) return validationError(`Максимум ${STYLE_CHAR_LIMIT} символов`, "style");
      if (!cleanTitle) return validationError("Укажите название", "title");
      if (cleanTitle.length > TITLE_CHAR_LIMIT) return validationError(`Максимум ${TITLE_CHAR_LIMIT} символов`, "title");
      if (!isInstrumental && !cleanLyrics) return validationError("Добавьте точный текст песни", "prompt");
      if (cleanLyrics.length > CUSTOM_PROMPT_LIMIT) return validationError(`Максимум ${CUSTOM_PROMPT_LIMIT} символов`, "prompt");
    } else {
      const promptLimit = audioReferenceUrl ? UPLOAD_COVER_PROMPT_LIMIT : STANDARD_PROMPT_LIMIT;
      if (!cleanPrompt) return validationError("Опишите песню, которую нужно создать", "prompt");
      if (cleanPrompt.length > promptLimit) return validationError(`Максимум ${promptLimit} символов`, "prompt");
    }

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
    const baseCallbackUrl = explicitCallbackUrl || `${Deno.env.get("SUPABASE_URL")}/functions/v1/suno-callback`;
    const callBackUrl = callbackSecret
      ? `${baseCallbackUrl}${baseCallbackUrl.includes('?') ? '&' : '?'}secret=${encodeURIComponent(callbackSecret)}`
      : baseCallbackUrl;

    const sunoPayload: Record<string, unknown> = {
      model: SUNO_MODEL,
      customMode: isCustomMode,
      instrumental: isInstrumental,
      callBackUrl,
    };

    if (cleanNegativeTags) {
      sunoPayload.negativeTags = cleanNegativeTags;
      console.log(`Negative tags for Suno: ${sunoPayload.negativeTags}`);
    }

    if (!isInstrumental && (vocalGender === 'm' || vocalGender === 'f')) {
      sunoPayload.vocalGender = vocalGender;
      console.log(`Vocal gender for Suno: ${sunoPayload.vocalGender}`);
    }

    if (isCustomMode && personaId) {
      sunoPayload.personaId = personaId;
      sunoPayload.personaModel = personaModel || "style_persona";
      console.log(`Persona for Suno: ${personaId}`);
    }

    if (parsedStyleWeight !== undefined) sunoPayload.styleWeight = parsedStyleWeight;
    if (parsedWeirdness !== undefined) sunoPayload.weirdnessConstraint = parsedWeirdness;
    if (parsedAudioWeight !== undefined) sunoPayload.audioWeight = parsedAudioWeight;

    if (isCustomMode) {
      if (!isInstrumental) sunoPayload.prompt = cleanLyrics;
      sunoPayload.style = cleanedStyle;
      sunoPayload.title = cleanTitle;
      if (parsedDuration !== undefined) sunoPayload.duration = parsedDuration;
      console.log(`Final style for Suno (${cleanedStyle.length} chars): ${cleanedStyle}`);
    } else {
      sunoPayload.prompt = cleanPrompt;
    }

    let sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate`;

    if (audioReferenceUrl) {
      if (audioReferenceUrl.includes("localhost") || audioReferenceUrl.includes("127.0.0.1")) {
        return new Response(
          JSON.stringify({ error: "Генерация с аудиореференсом недоступна на localhost: AIMUZA не может скачать файл с http://localhost. Тестируйте эту функцию на production-сайте." }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate/upload-cover`;
      sunoPayload.uploadUrl = audioReferenceUrl;
      console.log("Using upload-cover endpoint with audio reference");
    }

    console.log("Sending to Suno API:", JSON.stringify(sunoPayload));
    console.log("Endpoint:", sunoEndpoint);

    const sunoResponse = await fetch(sunoEndpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    console.log("Suno API response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      const rawErrorMessage = sunoData.msg || "Failed to start generation";
      const errorCode = sunoData.code || sunoResponse.status || 500;

      const errorInfo = getSunoErrorMessage(errorCode, rawErrorMessage);
      const russianErrorMessage = errorInfo.short;

      console.error(`Suno API error (${errorCode}): ${rawErrorMessage} -> ${russianErrorMessage}`);

      await supabaseClient
        .from("tracks")
        .update({
          status: "failed",
          error_message: russianErrorMessage
        })
        .in("id", allTrackIds)
        .eq("user_id", user.id);

      const { data: logs } = await supabaseClient
        .from("generation_logs")
        .select("id, cost_rub")
        .in("track_id", allTrackIds)
        .eq("user_id", user.id)
        .eq("status", "pending");

      let totalRefund = 0;
      if (logs && logs.length > 0) {
        totalRefund = logs.reduce((sum, log) => sum + (log.cost_rub || 0), 0);

        await supabaseClient
          .from("generation_logs")
          .update({ status: "failed" })
          .in("id", logs.map(l => l.id));

        if (totalRefund > 0) {
          const { error: refundError } = await supabaseAdmin.rpc("refund_generation_failed", {
            p_user_id: user.id,
            p_amount: totalRefund,
            p_track_id: trackId,
            p_description: `Возврат за неудачную генерацию`,
          });

          if (refundError) {
            console.error(`Refund failed for track ${trackId}:`, refundError);
          } else {
            console.log(`Refunded ${totalRefund} to user ${user.id}`);
            await Promise.all(logs.map((log) =>
              supabaseAdmin
                .from("generation_logs")
                .update({ refund_rub: log.cost_rub || 0 })
                .eq("id", log.id)
            ));
          }
        }
      }

      await supabaseClient
        .from("tracks")
        .update({ status: "failed", error_message: russianErrorMessage })
        .eq("user_id", user.id)
        .in("id", allTrackIds);

      if (totalRefund > 0) {
        await supabaseAdmin
          .from("notifications")
          .insert({
            user_id: user.id,
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

    const taskId = sunoData.data?.taskId || sunoData.data?.task_id || sunoData.taskId || sunoData.task_id;
    console.log(`Generation started with task ID: ${taskId} (raw data keys: ${JSON.stringify(Object.keys(sunoData.data || {}))})`);

    if (taskId) {
      // Fetch all tracks in the pair by their IDs (reliable, no created_at matching)
      const { data: pairTracks, error: pairErr } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description")
        .in("id", allTrackIds);

      if (pairErr) console.error("Error fetching pair tracks:", pairErr);

      const tracksToUpdate = pairTracks && pairTracks.length > 0 ? pairTracks : [{ id: trackId, title: null, description: null }];

      console.log(`Storing task_id ${taskId} in ${tracksToUpdate.length} tracks [${allTrackIds.join(", ")}]`);

      for (const track of tracksToUpdate) {
        if (track.description?.includes("[task_id:")) {
          console.log(`Track ${track.id} (${track.title}) already has task_id, skipping`);
          continue;
        }

        const existingDesc = track.description || "";
        const newDesc = existingDesc
          ? `${existingDesc}\n\n[task_id: ${taskId}]`
          : `[task_id: ${taskId}]`;

        const { error: updErr } = await supabaseAdmin
          .from("tracks")
          .update({ description: newDesc })
          .eq("id", track.id);

        if (updErr) console.error(`Failed to store task_id in track ${track.id}:`, updErr);
        else console.log(`Stored task_id ${taskId} in track ${track.id} (${track.title})`);
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        taskId,
        message: "Generation started successfully"
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in suno-generate:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: "Произошла непредвиденная ошибка. Попробуйте позже." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
