import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const WAV_TTL_DAYS = 7;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

async function processWavViaFfmpeg(
  rawWavUrl: string,
  trackTitle: string,
  artistName: string,
  ffmpegApiUrl: string,
  ffmpegApiSecret: string,
): Promise<string | null> {
  try {
    const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "");
    console.log(`[wav-cb] Processing WAV via ffmpeg-api: ${baseUrl}/process-wav`);

    const resp = await fetch(`${baseUrl}/process-wav`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ffmpegApiSecret,
      },
      body: JSON.stringify({
        audio_url: rawWavUrl,
        target_lufs: -14,
        metadata: {
          title: trackTitle || "",
          artist: artistName || "AIMuza Artist",
          copyright: `© ${new Date().getFullYear()} ${artistName || "AIMuza Artist"} via AIMuza`,
          comment: "Generated with AIMuza - aimuza.ru",
        },
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error(`[wav-cb] ffmpeg-api error ${resp.status}: ${errText}`);
      return null;
    }

    const result = await resp.json();
    let outputUrl = result.output_url;
    console.log(`[wav-cb] ffmpeg-api processed OK: ${outputUrl}, LUFS ${result.original_lufs} → ${result.normalized_lufs}`);

    // Rewrite public URL to internal Docker address
    if (outputUrl && outputUrl.includes("/output/")) {
      const filename = outputUrl.split("/output/").pop();
      if (filename) {
        outputUrl = `${baseUrl}/output/${filename}`;
        console.log(`[wav-cb] Rewrote to internal URL: ${outputUrl}`);
      }
    }

    return outputUrl;
  } catch (err) {
    console.error(`[wav-cb] ffmpeg processing error:`, err);
    return null;
  }
}

async function copyFileToStorage(
  supabaseAdmin: SupabaseClient,
  externalUrl: string,
  bucket: string,
  filePath: string
): Promise<string | null> {
  try {
    console.log(`[wav-cb] Downloading file from: ${externalUrl}`);
    const response = await fetch(externalUrl);
    if (!response.ok) {
      console.error(`[wav-cb] Download failed: ${response.status} ${response.statusText}`);
      return null;
    }

    const blob = await response.blob();
    const arrayBuffer = await blob.arrayBuffer();
    const uint8Array = new Uint8Array(arrayBuffer);

    if (uint8Array.length < 1000) {
      console.error(`[wav-cb] File too small (${uint8Array.length} bytes), likely not audio`);
      return null;
    }

    console.log(`[wav-cb] Downloaded ${uint8Array.length} bytes, uploading to ${bucket}/${filePath}`);

    const { error: uploadError } = await supabaseAdmin.storage
      .from(bucket)
      .upload(filePath, uint8Array, {
        contentType: "audio/wav",
        upsert: true,
      });

    if (uploadError) {
      console.error(`[wav-cb] Upload error:`, uploadError);
      return null;
    }

    const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    const publicUrl = `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`;

    console.log(`[wav-cb] File uploaded: ${publicUrl}`);
    return publicUrl;
  } catch (err) {
    console.error(`[wav-cb] Error copying file:`, err);
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const payload = await req.json();
    console.log("WAV callback received:", JSON.stringify(payload));

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
    const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");

    const { code, data, msg } = payload;

    if (code === 200 && data?.audio_wav_url) {
      const originalWavUrl = data.audio_wav_url;
      const taskId = data.task_id;

      console.log(`WAV conversion success! taskId: ${taskId}, wavUrl: ${originalWavUrl}`);

      const { data: addons } = await supabase
        .from("track_addons")
        .select("id, track_id, result_url")
        .eq("status", "processing")
        .order("created_at", { ascending: false });

      let matchedAddon = null;

      if (addons && taskId) {
        for (const addon of addons) {
          try {
            if (addon.result_url) {
              const resultData = typeof addon.result_url === 'string' 
                ? JSON.parse(addon.result_url) 
                : addon.result_url;
              if (resultData.wav_task_id === taskId) {
                matchedAddon = addon;
                break;
              }
            }
          } catch (e) {
            console.log("Error parsing result_url:", e);
          }
        }
      }

      if (!matchedAddon && addons && addons.length > 0) {
        matchedAddon = addons[0];
        console.log("No task_id match, using most recent addon");
      }

      if (matchedAddon) {
        console.log(`Updating addon ${matchedAddon.id} with WAV URL`);

        const { data: track } = await supabase
          .from("tracks")
          .select("user_id, title")
          .eq("id", matchedAddon.track_id)
          .maybeSingle();

        const { data: profile } = track ? await supabase
          .from("profiles")
          .select("username")
          .eq("user_id", track.user_id)
          .single() : { data: null };

        // Process through ffmpeg-api for normalization + distribution format
        let wavUrlToStore = originalWavUrl;
        if (ffmpegApiUrl && ffmpegApiSecret) {
          const processedUrl = await processWavViaFfmpeg(
            originalWavUrl,
            track?.title || "",
            profile?.username || "AIMuza Artist",
            ffmpegApiUrl,
            ffmpegApiSecret,
          );
          if (processedUrl) {
            wavUrlToStore = processedUrl;
          } else {
            console.warn("[wav-cb] ffmpeg processing failed, using raw WAV");
          }
        } else {
          console.log("[wav-cb] FFMPEG_API not configured, using raw WAV");
        }

        let finalWavUrl = wavUrlToStore;
        const wavFileName = `${matchedAddon.track_id}.wav`;
        const storedUrl = await copyFileToStorage(
          supabase,
          wavUrlToStore,
          "tracks",
          `wav/${wavFileName}`
        );
        if (storedUrl) {
          finalWavUrl = storedUrl;
          console.log(`WAV copied to storage: ${finalWavUrl}`);
        } else {
          console.warn(`Failed to copy WAV to storage, using source URL`);
        }

        const expiresAt = new Date(Date.now() + WAV_TTL_DAYS * 24 * 60 * 60 * 1000).toISOString();
        
        await supabase
          .from("track_addons")
          .update({ 
            status: "completed",
            result_url: finalWavUrl,
            updated_at: new Date().toISOString(),
          })
          .eq("id", matchedAddon.id);

        await supabase
          .from("tracks")
          .update({ 
            wav_url: finalWavUrl,
            wav_expires_at: expiresAt,
            updated_at: new Date().toISOString(),
          })
          .eq("id", matchedAddon.track_id);

        if (track) {
          await supabase.from("notifications").insert({
            user_id: track.user_id,
            type: "addon_completed",
            title: "WAV готов к скачиванию",
            message: `Трек "${track.title}" конвертирован в WAV (16-bit/44.1kHz). Доступен 7 дней.`,
            target_type: "track",
            target_id: matchedAddon.track_id,
            metadata: { wav_url: finalWavUrl, expires_at: expiresAt },
          });
        }

        console.log("WAV conversion completed and saved:", finalWavUrl, "expires:", expiresAt);
      } else {
        console.error("No matching addon found for task:", taskId);
      }
    } else {
      console.error("WAV conversion failed or unexpected format:", payload);
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    console.error("Error in wav-callback:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
