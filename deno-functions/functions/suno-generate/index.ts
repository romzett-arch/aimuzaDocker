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

    const { trackId, trackIds, prompt, lyrics, style, title, instrumental, audioReferenceUrl, negativeTags, vocalGender, personaId } = await req.json();

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

    const cleanedStyle = cleanStyleForSuno(style || "");
    console.log(`Cleaned style: ${cleanedStyle}`);

    const { error: updateError } = await supabaseClient
      .from("tracks")
      .update({ status: "processing", error_message: null })
      .in("id", allTrackIds)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("Failed to update track status:", updateError);
    }

    const STYLE_CHAR_LIMIT = 1000;
    const PROMPT_CHAR_LIMIT = 5000;
    const NON_CUSTOM_PROMPT_LIMIT = 500;

    const hasLyrics = !!lyrics && lyrics.trim().length > 0;
    const hasStyle = !!cleanedStyle && cleanedStyle.trim().length > 0;
    const useCustomMode = hasLyrics || hasStyle;

    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    const explicitCallbackUrl = Deno.env.get("SUNO_CALLBACK_URL");
    const baseCallbackUrl = explicitCallbackUrl || `${Deno.env.get("SUPABASE_URL")}/functions/v1/suno-callback`;
    const callBackUrl = callbackSecret
      ? `${baseCallbackUrl}${baseCallbackUrl.includes('?') ? '&' : '?'}secret=${encodeURIComponent(callbackSecret)}`
      : baseCallbackUrl;

    const sunoPayload: Record<string, unknown> = {
      model: "V5",
      customMode: useCustomMode,
      instrumental: instrumental || false,
      callBackUrl,
    };

    if (negativeTags && negativeTags.trim()) {
      sunoPayload.negativeTags = negativeTags.trim();
      console.log(`Negative tags for Suno: ${sunoPayload.negativeTags}`);
    }

    if (vocalGender && (vocalGender === 'm' || vocalGender === 'f')) {
      sunoPayload.vocalGender = vocalGender;
      console.log(`Vocal gender for Suno: ${sunoPayload.vocalGender}`);
    }

    if (personaId) {
      sunoPayload.personaId = personaId;
      console.log(`Persona for Suno: ${personaId}`);
    }

    if (useCustomMode) {
      if (hasLyrics) {
        sunoPayload.prompt = lyrics.slice(0, PROMPT_CHAR_LIMIT);
      } else {
        sunoPayload.customMode = false;
        sunoPayload.prompt = (prompt || cleanedStyle).slice(0, NON_CUSTOM_PROMPT_LIMIT);
      }

      let finalStyle = cleanedStyle || "pop";

      if (finalStyle.length > STYLE_CHAR_LIMIT) {
        const parts = finalStyle.split(", ");
        let truncated = "";
        for (const part of parts) {
          if ((truncated + ", " + part).length <= STYLE_CHAR_LIMIT) {
            truncated = truncated ? truncated + ", " + part : part;
          } else {
            break;
          }
        }
        finalStyle = truncated || finalStyle.slice(0, STYLE_CHAR_LIMIT);
        console.log(`Style truncated from ${cleanedStyle.length} to ${finalStyle.length} chars`);
      }

      sunoPayload.style = finalStyle;
      sunoPayload.title = (title || "Untitled").slice(0, 100);

      console.log(`Final style for Suno (${sunoPayload.style.length} chars): ${sunoPayload.style}`);
    } else {
      sunoPayload.prompt = (prompt || "").slice(0, NON_CUSTOM_PROMPT_LIMIT);
    }

    let sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate`;

    if (audioReferenceUrl) {
      if (audioReferenceUrl.includes("localhost") || audioReferenceUrl.includes("127.0.0.1")) {
        return new Response(
          JSON.stringify({ error: "Генерация с аудио-референсом недоступна на localhost: Suno не может скачать файл с http://localhost. Тестируйте эту функцию на продакшене (https://aimuza.ru)." }),
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
