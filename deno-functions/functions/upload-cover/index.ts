import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getSunoErrorMessage } from "./errors.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://api.sunoapi.org";

const STYLE_CHAR_LIMIT = 1000;
const PROMPT_CHAR_LIMIT = 5000;
const NON_CUSTOM_PROMPT_LIMIT = 500;
const TITLE_CHAR_LIMIT = 100;

const artistToStyleMap: Record<string, string> = {
  "Drake": "moody trap hip-hop with melodic hooks",
  "The Weeknd": "dark synth-pop R&B with falsetto vocals",
  "Taylor Swift": "catchy pop-country with storytelling lyrics",
  "Ed Sheeran": "acoustic pop folk with romantic themes",
  "Billie Eilish": "dark minimalist pop with whispered vocals",
  "Ariana Grande": "powerful pop R&B with high vocals",
  "Dua Lipa": "disco-influenced dance pop",
  "Bad Bunny": "reggaeton latin trap with urban beats",
  "Post Malone": "melodic hip-hop rock fusion",
  "Kendrick Lamar": "conscious lyrical hip-hop",
  "Beyoncé": "powerful R&B pop with soulful vocals",
  "BTS": "K-pop with dynamic choreography vibes",
  "Harry Styles": "70s inspired soft rock pop",
  "Doja Cat": "playful rap-pop with catchy hooks",
  "SZA": "neo-soul R&B with vulnerable lyrics",
  "Travis Scott": "atmospheric auto-tune trap",
  "Olivia Rodrigo": "emotional pop-rock with teen angst",
  "Lana Del Rey": "cinematic dreamy baroque pop",
  "Kanye West": "experimental hip-hop with gospel influences",
  "Bruno Mars": "funk pop with retro grooves",
  "Adele": "powerful ballads with soulful vocals",
  "Rihanna": "dancehall-influenced pop R&B",
  "Justin Bieber": "pop R&B with tropical influences",
  "Lady Gaga": "theatrical electro-pop",
  "Shakira": "latin pop with world music fusion",
  "Coldplay": "anthemic alternative rock with atmospheric synths",
  "Imagine Dragons": "arena rock with electronic elements",
  "Twenty One Pilots": "alternative hip-hop with electronic elements",
  "Maroon 5": "pop rock with funky grooves",
  "OneRepublic": "orchestral pop rock with uplifting themes",
};

function convertArtistToStyle(artistName: string): string {
  if (artistToStyleMap[artistName]) {
    return artistToStyleMap[artistName];
  }
  const lowerName = artistName.toLowerCase();
  for (const [artist, style] of Object.entries(artistToStyleMap)) {
    if (artist.toLowerCase() === lowerName) {
      return style;
    }
  }
  return "contemporary pop with modern production";
}

function cleanStyleForSuno(style: string): string {
  if (!style) return "";
  
  let cleanedStyle = style;
  for (const artistName of Object.keys(artistToStyleMap)) {
    const regex = new RegExp(`${artistName}\\s*style`, "gi");
    if (regex.test(cleanedStyle)) {
      cleanedStyle = cleanedStyle.replace(regex, convertArtistToStyle(artistName));
    }
    const standaloneRegex = new RegExp(`\\b${artistName}\\b`, "gi");
    if (standaloneRegex.test(cleanedStyle)) {
      cleanedStyle = cleanedStyle.replace(standaloneRegex, convertArtistToStyle(artistName));
    }
  }
  
  cleanedStyle = cleanedStyle.replace(/,\s*,/g, ",").replace(/\s+/g, " ").trim();
  return cleanedStyle;
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
      trackIds: rawTrackIds,
      sourceAudioUrl,
      prompt,
      style,
      title, 
      instrumental,
      customMode: rawCustomMode,
    } = await req.json();

    if (!trackId || !sourceAudioUrl) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: trackId, sourceAudioUrl" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const allTrackIds: string[] = Array.isArray(rawTrackIds) && rawTrackIds.length > 0
      ? rawTrackIds
      : [trackId];

    console.log(`Starting upload-cover for tracks [${allTrackIds.join(", ")}] by user ${user.id}`);
    console.log(`Source audio: ${sourceAudioUrl}`);
    console.log(`Style: ${style}, Instrumental: ${instrumental}`);

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

    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    const explicitCallbackUrl = Deno.env.get("SUNO_CALLBACK_URL");
    const baseCallbackUrl = explicitCallbackUrl || `${Deno.env.get("SUPABASE_URL")}/functions/v1/suno-callback`;
    const callBackUrl = callbackSecret
      ? `${baseCallbackUrl}${baseCallbackUrl.includes('?') ? '&' : '?'}secret=${encodeURIComponent(callbackSecret)}`
      : baseCallbackUrl;

    const hasLyrics = !!prompt && prompt.trim().length > 0;
    const hasStyle = !!cleanedStyle && cleanedStyle.trim().length > 0;
    const useCustomMode = rawCustomMode !== undefined ? rawCustomMode : (hasLyrics || hasStyle);

    const sunoPayload: Record<string, unknown> = {
      uploadUrl: sourceAudioUrl,
      customMode: useCustomMode,
      instrumental: instrumental || false,
      model: "V5",
      callBackUrl,
    };

    if (useCustomMode) {
      if (!instrumental && hasLyrics) {
        sunoPayload.prompt = prompt.slice(0, PROMPT_CHAR_LIMIT);
      }

      let finalStyle = cleanedStyle || "pop";
      if (finalStyle.length > STYLE_CHAR_LIMIT) {
        const parts = finalStyle.split(", ");
        let truncated = "";
        for (const part of parts) {
          if ((truncated + ", " + part).length <= STYLE_CHAR_LIMIT) {
            truncated = truncated ? truncated + ", " + part : part;
          } else break;
        }
        finalStyle = truncated || finalStyle.slice(0, STYLE_CHAR_LIMIT);
      }
      sunoPayload.style = finalStyle;
      sunoPayload.title = (title || "Untitled").slice(0, TITLE_CHAR_LIMIT);

      console.log(`Custom mode: style="${sunoPayload.style}" (${String(sunoPayload.style).length} chars), title="${sunoPayload.title}"`);
    } else {
      if (prompt) sunoPayload.prompt = prompt.slice(0, NON_CUSTOM_PROMPT_LIMIT);
    }

    console.log("Sending to Suno upload-cover API:", JSON.stringify(sunoPayload));

    const sunoResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/upload-cover`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    console.log("Suno upload-cover response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      const rawErrorMessage = sunoData.msg || "Failed to start cover generation";
      const errorCode = sunoData.code || sunoResponse.status || 500;
      const errorInfo = getSunoErrorMessage(errorCode, rawErrorMessage);
      const russianErrorMessage = errorInfo.short;

      console.error(`Suno API error (${errorCode}): ${rawErrorMessage} -> ${russianErrorMessage}`);

      await supabaseClient
        .from("tracks")
        .update({ status: "failed", error_message: russianErrorMessage })
        .in("id", allTrackIds)
        .eq("user_id", user.id);

      // Refund: find pending generation_logs for these tracks
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
              description: "Возврат за неудачную генерацию кавера",
              reference_id: trackId,
              reference_type: "track",
              metadata: { error: russianErrorMessage },
            });

            console.log(`Refunded ${totalRefund} to user ${user.id}`);
          }
        }
      }

      await supabaseAdmin
        .from("notifications")
        .insert({
          user_id: user.id,
          type: "refund",
          title: `Ошибка: ${russianErrorMessage}`,
          message: `${errorInfo.full}${totalRefund > 0 ? `\n\nВам возвращено ${totalRefund} ₽` : ""}`,
          target_type: "track",
          target_id: trackId,
        });

      return new Response(
        JSON.stringify({
          error: russianErrorMessage,
          details: errorInfo.full,
          refunded: totalRefund > 0,
          refundAmount: totalRefund,
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Robust taskId extraction (Suno API may use different key names)
    const taskId = sunoData.data?.taskId || sunoData.data?.task_id || sunoData.taskId || sunoData.task_id;
    console.log(`Cover generation started with task ID: ${taskId} (raw data keys: ${JSON.stringify(Object.keys(sunoData.data || {}))})`);

    // Store task_id in track descriptions so suno-callback can find them
    if (taskId) {
      const { data: pairTracks, error: pairErr } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description")
        .in("id", allTrackIds);

      if (pairErr) console.error("Error fetching pair tracks:", pairErr);

      const tracksToUpdate = pairTracks && pairTracks.length > 0
        ? pairTracks
        : [{ id: trackId, title: null, description: null }];

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
        message: "Cover generation started successfully" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in upload-cover:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
