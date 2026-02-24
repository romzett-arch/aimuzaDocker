import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, WAV_TTL_DAYS } from "./constants.ts";
import { validateAuth, AuthError } from "./auth.ts";
import { processWavViaFfmpeg, copyWavToStorage } from "./utils.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  try {
    let userId: string | null;
    let isInternalCall: boolean;
    try {
      const auth = await validateAuth(req, supabaseUrl, supabaseServiceKey, supabaseAnonKey);
      userId = auth.userId;
      isInternalCall = auth.isInternalCall;
    } catch (e) {
      if (e instanceof AuthError) {
        return new Response(
          JSON.stringify({ error: e.message }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      throw e;
    }

    const body = await req.json();
    const { track_id, audio_id } = body;

    console.log("Convert to WAV request:", { track_id, audio_id, userId, isInternalCall });

    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
    const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, suno_audio_id, title, description, audio_url, wav_url")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    if (track.wav_url) {
      console.log("WAV already exists on track:", track.wav_url);
      return new Response(
        JSON.stringify({ success: true, wav_url: track.wav_url, message: "WAV already available" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!isInternalCall && track.user_id !== userId) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let taskId: string | null = null;
    if (track.description) {
      const taskIdMatch = track.description.match(/\[task_id:\s*([^\]]+)\]/);
      if (taskIdMatch) {
        taskId = taskIdMatch[1].trim();
      }
    }

    let audioId = audio_id || track.suno_audio_id;

    if (!taskId) {
      throw new Error("Track has no Suno task ID for WAV conversion");
    }

    if (!audioId && taskId) {
      console.log(`audioId missing, fetching from erweima.ai record-info for taskId=${taskId}`);
      try {
        const infoResp = await fetch(
          `https://apibox.erweima.ai/api/v1/generate/record-info?taskId=${taskId}`,
          { headers: { "Authorization": `Bearer ${SUNO_API_KEY}` } }
        );
        const infoData = await infoResp.json();
        if (infoData.code === 200 && infoData.data?.response?.sunoData) {
          const sunoRecords = infoData.data.response.sunoData;
          const titleSuffix = track.title?.match(/\(v(\d+)\)/)?.[1];
          const idx = titleSuffix ? parseInt(titleSuffix) - 1 : 0;
          const matched = sunoRecords[idx] || sunoRecords[0];
          if (matched?.id) {
            audioId = matched.id;
            console.log(`Resolved audioId from erweima: ${audioId}`);
            await supabase.from("tracks").update({ suno_audio_id: audioId }).eq("id", track_id);
          }
        }
      } catch (lookupErr) {
        console.error("Failed to lookup audioId from erweima:", lookupErr);
      }
    }

    if (!audioId) {
      throw new Error("Track has no Suno audio ID and could not resolve it. Please regenerate the track.");
    }

    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id, price_rub")
      .eq("name", "convert_wav")
      .single();

    if (!addonService) {
      throw new Error("WAV conversion service not found");
    }

    const callbackUrl = `${supabaseUrl}/functions/v1/wav-callback`;

    const response = await fetch("https://api.sunoapi.org/api/v1/wav/generate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify({
        taskId: taskId,
        audioId: audioId,
        callBackUrl: callbackUrl,
      }),
    });

    const result = await response.json();
    console.log("Suno WAV API response:", result);

    if (result.code === 409 && result.data?.taskId) {
      console.log("WAV already exists, fetching record-info...");

      const statusResponse = await fetch(`https://api.sunoapi.org/api/v1/wav/record-info?taskId=${result.data.taskId}`, {
        method: "GET",
        headers: {
          "Authorization": `Bearer ${SUNO_API_KEY}`,
        },
      });

      const statusResult = await statusResponse.json();
      console.log("WAV record-info response:", statusResult);

      if (statusResult.code === 200 && statusResult.data?.response?.audioWavUrl) {
        const originalWavUrl = statusResult.data.response.audioWavUrl;
        console.log("Found WAV URL from record-info:", originalWavUrl);

        const { data: profile } = await supabase
          .from("profiles")
          .select("username")
          .eq("user_id", track.user_id)
          .single();
        const artistName = profile?.username || "AIMuza Artist";

        let wavUrlToStore = originalWavUrl;
        if (ffmpegApiUrl && ffmpegApiSecret) {
          const processedUrl = await processWavViaFfmpeg(
            originalWavUrl, track.title, artistName, ffmpegApiUrl, ffmpegApiSecret,
          );
          if (processedUrl) {
            wavUrlToStore = processedUrl;
          } else {
            console.warn("[convert-wav] ffmpeg processing failed, using raw WAV");
          }
        }

        let finalWavUrl = wavUrlToStore;
        const storedUrl = await copyWavToStorage(supabase, wavUrlToStore, track_id);
        if (storedUrl) {
          finalWavUrl = storedUrl;
        }

        const expiresAt = new Date(Date.now() + WAV_TTL_DAYS * 24 * 60 * 60 * 1000).toISOString();

        await supabase
          .from("tracks")
          .update({
            wav_url: finalWavUrl,
            wav_expires_at: expiresAt,
            updated_at: new Date().toISOString(),
          })
          .eq("id", track_id);

        await supabase.from("track_addons").upsert({
          track_id,
          addon_service_id: addonService.id,
          status: "completed",
          result_url: finalWavUrl,
          updated_at: new Date().toISOString(),
        }, {
          onConflict: "track_id,addon_service_id",
        });

        await supabase.from("notifications").insert({
          user_id: track.user_id,
          type: "addon_completed",
          title: "WAV готов к скачиванию",
          message: `Трек "${track.title}" конвертирован в WAV (16-bit/44.1kHz). Доступен 7 дней.`,
          target_type: "track",
          target_id: track_id,
          metadata: { wav_url: finalWavUrl, expires_at: expiresAt },
        });

        return new Response(
          JSON.stringify({ success: true, wav_url: finalWavUrl, expires_at: expiresAt, message: "WAV ready" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      await supabase.from("track_addons").upsert({
        track_id,
        addon_service_id: addonService.id,
        status: "processing",
        result_url: JSON.stringify({
          wav_task_id: result.data.taskId,
          suno_audio_id: audioId,
        }),
        updated_at: new Date().toISOString(),
      }, {
        onConflict: "track_id,addon_service_id",
      });

      return new Response(
        JSON.stringify({ success: true, taskId: result.data.taskId, message: "WAV conversion in progress" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (result.code !== 200) {
      throw new Error(result.msg || "Failed to start WAV conversion");
    }

    await supabase.from("track_addons").upsert({
      track_id,
      addon_service_id: addonService.id,
      status: "processing",
      result_url: JSON.stringify({
        wav_task_id: result.data?.taskId,
        suno_audio_id: audioId,
      }),
      updated_at: new Date().toISOString(),
    }, {
      onConflict: "track_id,addon_service_id",
    });

    return new Response(
      JSON.stringify({ success: true, taskId: result.data?.taskId }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in convert-to-wav:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
