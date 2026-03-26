import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

function getTaskId(payload: Record<string, any>): string | null {
  return payload?.data?.task_id
    ?? payload?.data?.taskId
    ?? payload?.task_id
    ?? payload?.taskId
    ?? null;
}

function getWavUrl(payload: Record<string, any>): string | null {
  return payload?.data?.audio_wav_url
    ?? payload?.data?.audioWavUrl
    ?? payload?.data?.response?.audio_wav_url
    ?? payload?.data?.response?.audioWavUrl
    ?? null;
}

function toReachableAudioUrl(url: string, ffmpegApiUrl?: string): string {
  if (!ffmpegApiUrl) return url;

  try {
    const target = new URL(url);
    if (target.pathname.startsWith("/api/ffmpeg/")) {
      const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "").replace(/\/$/, "");
      return `${baseUrl}${target.pathname.replace(/^\/api\/ffmpeg/, "")}${target.search}`;
    }
  } catch {
    return url;
  }

  return url;
}

async function isUsableAudioUrl(url: string, ffmpegApiUrl?: string): Promise<boolean> {
  try {
    const response = await fetch(toReachableAudioUrl(url, ffmpegApiUrl), { method: "HEAD" });
    if (!response.ok) {
      console.warn(`[wav-cb] HEAD check failed for ${url}: ${response.status}`);
      return false;
    }

    const contentType = response.headers.get("content-type")?.toLowerCase() || "";
    if (contentType.includes("text/html") || contentType.includes("application/json")) {
      console.warn(`[wav-cb] Unexpected content-type for ${url}: ${contentType}`);
      return false;
    }

    const contentLength = Number(response.headers.get("content-length") || "0");
    if (contentLength > 0 && contentLength < 1000) {
      console.warn(`[wav-cb] Suspiciously small file for ${url}: ${contentLength} bytes`);
      return false;
    }

    return true;
  } catch (error) {
    console.warn(`[wav-cb] HEAD check error for ${url}:`, error);
    return false;
  }
}

async function processWavViaFfmpeg(
  rawWavUrl: string,
  trackTitle: string,
  artistName: string,
  publisherName: string,
  cabinetId: string,
  ffmpegApiUrl: string,
  ffmpegApiSecret: string,
  ffmpegPublicUrl?: string,
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
          album: "AIMuza WAV Export",
          publisher: publisherName || "AIMuza",
          copyright: `© ${new Date().getFullYear()} ${artistName || "AIMuza Artist"} via ${publisherName || "AIMuza"}`,
          comment: `Generated with AIMuza - aimuza.ru | Cabinet ID: ${cabinetId}`,
          TXXX_AIMUZA_CABINET_ID: cabinetId || "",
          TXXX_AIMUZA_PUBLISHER: publisherName || "AIMuza",
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
    console.log(`[wav-cb] ffmpeg-api processed OK: ${outputUrl}`);

    if (outputUrl && outputUrl.includes("/output/")) {
      const filename = outputUrl.split("/output/").pop();
      if (filename) {
        const publicBase = ffmpegPublicUrl || baseUrl;
        outputUrl = `${publicBase}/output/${filename}`;
        console.log(`[wav-cb] Public URL: ${outputUrl}`);
      }
    }

    if (!outputUrl) {
      console.warn("[wav-cb] ffmpeg returned empty output_url");
      return null;
    }

    const isReachable = await isUsableAudioUrl(outputUrl, ffmpegApiUrl);
    if (!isReachable) {
      console.warn(`[wav-cb] ffmpeg output URL is not downloadable: ${outputUrl}`);
      return null;
    }

    return outputUrl;
  } catch (err) {
    console.error(`[wav-cb] ffmpeg processing error:`, err);
    return null;
  }
}

async function copyWavToStorage(
  supabase: ReturnType<typeof createClient>,
  externalUrl: string,
  trackId: string,
): Promise<string | null> {
  try {
    const response = await fetch(externalUrl);
    if (!response.ok) {
      console.error(`[wav-cb] Storage copy download failed: ${response.status}`);
      return null;
    }

    const uint8Array = new Uint8Array(await response.arrayBuffer());
    if (uint8Array.length < 1000) {
      console.error(`[wav-cb] Storage copy file too small: ${uint8Array.length} bytes`);
      return null;
    }

    const filePath = `wav/${trackId}.wav`;
    const { error } = await supabase.storage
      .from("tracks")
      .upload(filePath, uint8Array, { contentType: "audio/wav", upsert: true });

    if (error) {
      console.error("[wav-cb] Storage upload error:", error);
      return null;
    }

    const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    return `${baseUrl}/storage/v1/object/public/tracks/${filePath}`;
  } catch (error) {
    console.error("[wav-cb] Storage copy error:", error);
    return null;
  }
}

async function resumeReleasePackageBuild(
  trackId: string,
): Promise<void> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseServiceKey) return;

  try {
    const response = await fetch(`${supabaseUrl.replace(/\/$/, "")}/functions/v1/generate-release-package`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Authorization": `Bearer ${supabaseServiceKey}`,
      },
      body: JSON.stringify({ track_id: trackId }),
    });

    const payload = await response.text();
    console.log(`[wav-cb] release-package resume ${response.status}: ${payload}`);
  } catch (error) {
    console.error("[wav-cb] release-package resume failed:", error);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  let payload: Record<string, any> | null = null;

  try {
    payload = await req.json();
    console.log("WAV callback received:", JSON.stringify(payload));

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
    const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");
    const ffmpegPublicUrl = Deno.env.get("FFMPEG_PUBLIC_URL");

    const { code, msg } = payload;
    const taskId = getTaskId(payload);
    const originalWavUrl = getWavUrl(payload);

    if (Number(code) === 200 && originalWavUrl) {
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
              const resultData = typeof addon.result_url === "string"
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
        console.log("No task_id match, using most recent processing addon");
      }

      if (matchedAddon) {
        console.log(`Updating addon ${matchedAddon.id} with WAV URL`);

        const { data: track } = await supabase
          .from("tracks")
          .select("user_id, title, performer_name, label_name")
          .eq("id", matchedAddon.track_id)
          .maybeSingle();

        const { data: profile } = track
          ? await supabase.from("profiles").select("username, display_name, short_id").eq("user_id", track.user_id).single()
          : { data: null };

        if (!ffmpegApiUrl || !ffmpegApiSecret) {
          throw new Error("FFmpeg WAV processing unavailable");
        }

        const finalWavUrl = await processWavViaFfmpeg(
          originalWavUrl,
          track?.title || "",
          track?.performer_name || profile?.display_name || profile?.username || "AIMuza Artist",
          track?.label_name || "AIMuza",
          profile?.short_id || track?.user_id || "",
          ffmpegApiUrl,
          ffmpegApiSecret,
          ffmpegPublicUrl ?? undefined,
        );

        if (!finalWavUrl) {
          throw new Error("FFmpeg WAV processing failed");
        }

        const stableWavUrl = await copyWavToStorage(supabase, finalWavUrl, matchedAddon.track_id);
        if (!stableWavUrl) {
          throw new Error("Failed to persist WAV to storage");
        }

        await supabase
          .from("track_addons")
          .update({
            status: "completed",
            result_url: stableWavUrl,
            updated_at: new Date().toISOString(),
          })
          .eq("id", matchedAddon.id);

        console.log("WAV conversion completed:", stableWavUrl);

        const { data: pendingReleasePackage } = await supabase
          .from("release_packages")
          .select("id")
          .eq("track_id", matchedAddon.track_id)
          .eq("status", "processing")
          .maybeSingle();

        if (pendingReleasePackage?.id) {
          await resumeReleasePackageBuild(matchedAddon.track_id);
        }
      } else {
        console.error("No matching addon found for task:", taskId);
      }
    } else {
      console.error("WAV conversion failed or unexpected format:", payload);
      if (taskId) {
        const { data: addons } = await supabase
          .from("track_addons")
          .select("id, track_id, result_url")
          .eq("status", "processing");
        for (const addon of addons || []) {
          try {
            const resultData = typeof addon.result_url === "string"
              ? JSON.parse(addon.result_url)
              : addon.result_url;
            if (resultData?.wav_task_id === taskId) {
              const { data: track } = await supabase.from("tracks").select("user_id").eq("id", addon.track_id).single();
              const { data: svc } = await supabase.from("addon_services").select("price_rub").eq("name", "convert_wav").single();
              if (track && svc?.price_rub) {
                await supabase.rpc("refund_generation_failed", {
                  p_user_id: track.user_id,
                  p_amount: svc.price_rub,
                  p_track_id: addon.track_id,
                  p_description: `Возврат за ошибку конвертации в WAV: ${msg || "Ошибка Suno API"}`,
                });
                console.log(`Refunded ${svc.price_rub} ₽ for failed WAV callback`);
              }
              await supabase.from("track_addons").update({ status: "failed" }).eq("id", addon.id);
              break;
            }
          } catch (e) {
            console.error("Refund/update failed for addon:", addon.id, e);
          }
        }
      }
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    console.error("Error in wav-callback:", error);
    const message = error instanceof Error ? error.message : "Unknown error";

    try {
      const taskId = payload ? getTaskId(payload) : null;
      if (taskId) {
        const { data: addons } = await createClient(
          Deno.env.get("SUPABASE_URL")!,
          Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
        )
          .from("track_addons")
          .select("id, track_id, result_url")
          .eq("status", "processing");

        for (const addon of addons || []) {
          try {
            const resultData = typeof addon.result_url === "string"
              ? JSON.parse(addon.result_url)
              : addon.result_url;
            if (resultData?.wav_task_id === taskId) {
              const supabase = createClient(
                Deno.env.get("SUPABASE_URL")!,
                Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
              );
              const { data: track } = await supabase.from("tracks").select("user_id").eq("id", addon.track_id).single();
              const { data: svc } = await supabase.from("addon_services").select("price_rub").eq("name", "convert_wav").single();
              if (track && svc?.price_rub) {
                await supabase.rpc("refund_generation_failed", {
                  p_user_id: track.user_id,
                  p_amount: svc.price_rub,
                  p_track_id: addon.track_id,
                  p_description: `Возврат за ошибку конвертации в WAV: ${message}`,
                });
              }
              await supabase.from("track_addons").update({ status: "failed" }).eq("id", addon.id);
              break;
            }
          } catch (innerError) {
            console.error("wav-callback failure recovery error:", innerError);
          }
        }
      }
    } catch (recoveryError) {
      console.error("wav-callback recovery failed:", recoveryError);
    }

    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
