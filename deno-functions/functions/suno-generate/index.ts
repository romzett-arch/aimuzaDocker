import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getSunoErrorMessage } from "./errors.ts";
import { cleanStyleForSuno } from "./styleUtils.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://apibox.erweima.ai";

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

    const { trackId, prompt, lyrics, style, title, instrumental, audioReferenceUrl, negativeTags, vocalGender } = await req.json();

    if (!trackId) {
      return new Response(
        JSON.stringify({ error: "Missing required field: trackId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Starting generation for track ${trackId} by user ${user.id}`);
    console.log(`Original prompt: ${prompt}`);
    console.log(`Original style: ${style}`);
    console.log(`Instrumental: ${instrumental}`);
    console.log(`Audio reference URL: ${audioReferenceUrl || 'none'}`);
    console.log(`Negative tags: ${negativeTags || 'none'}`);
    console.log(`Vocal gender: ${vocalGender || 'none'}`);

    const cleanedStyle = cleanStyleForSuno(style || "");
    console.log(`Cleaned style: ${cleanedStyle}`);

    const { error: updateError } = await supabaseClient
      .from("tracks")
      .update({ status: "processing", error_message: null })
      .eq("id", trackId)
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

    if (useCustomMode) {
      if (hasLyrics) {
        sunoPayload.prompt = lyrics.slice(0, PROMPT_CHAR_LIMIT);
      } else if (instrumental) {
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
        .eq("id", trackId)
        .eq("user_id", user.id);

      const { data: allTracks } = await supabaseClient
        .from("tracks")
        .select("id")
        .eq("user_id", user.id)
        .in("status", ["pending", "processing"]);

      const trackIds = allTracks?.map(t => t.id) || [trackId];

      const { data: logs } = await supabaseClient
        .from("generation_logs")
        .select("id, cost_rub")
        .in("track_id", trackIds)
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
          const { data: profile } = await supabaseClient
            .from("profiles")
            .select("balance")
            .eq("user_id", user.id)
            .single();

          if (profile) {
            const newBalance = (profile.balance || 0) + totalRefund;
            await supabaseClient
              .from("profiles")
              .update({ balance: newBalance })
              .eq("user_id", user.id);

            await supabaseClient.from("balance_transactions").insert({
              user_id: user.id,
              amount: totalRefund,
              balance_after: newBalance,
              type: "refund",
              description: `Возврат за неудачную генерацию`,
              reference_id: trackId,
              reference_type: "track",
              metadata: { error: russianErrorMessage },
            });

            console.log(`Refunded ${totalRefund} to user ${user.id}`);
          }
        }
      }

      await supabaseClient
        .from("tracks")
        .update({ status: "failed", error_message: russianErrorMessage })
        .eq("user_id", user.id)
        .in("status", ["pending", "processing"]);

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

    const taskId = sunoData.data?.taskId;
    console.log(`Generation started with task ID: ${taskId}`);

    if (taskId) {
      const { data: currentTrack } = await supabaseClient
        .from("tracks")
        .select("id, title, description, created_at")
        .eq("id", trackId)
        .single();

      if (currentTrack) {
        const baseTitle = (currentTrack.title || "").replace(/\s*\(v\d+\)$/, "").trim();

        const { data: pairedTracks } = await supabaseClient
          .from("tracks")
          .select("id, title, description, created_at")
          .eq("user_id", user.id)
          .eq("created_at", currentTrack.created_at);

        const tracksToUpdate = pairedTracks?.filter(t => {
          const tBaseTitle = (t.title || "").replace(/\s*\(v\d+\)$/, "").trim();
          return tBaseTitle === baseTitle;
        }) || [currentTrack];

        console.log(`Found ${tracksToUpdate.length} tracks in pair to update with task_id`);

        for (const track of tracksToUpdate) {
          if (track.description?.includes("[task_id:")) {
            console.log(`Track ${track.id} (${track.title}) already has task_id, skipping to prevent overwrite`);
            continue;
          }

          const existingDesc = track.description || "";
          const newDesc = existingDesc
            ? `${existingDesc}\n\n[task_id: ${taskId}]`
            : `[task_id: ${taskId}]`;

          await supabaseClient
            .from("tracks")
            .update({ description: newDesc })
            .eq("id", track.id);

          console.log(`Stored task_id ${taskId} in track ${track.id} (${track.title})`);
        }
      } else {
        const newDesc = `[task_id: ${taskId}]`;

        await supabaseClient
          .from("tracks")
          .update({ description: newDesc })
          .eq("id", trackId);

        console.log(`Stored task_id ${taskId} in track ${trackId} (fallback)`);
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
