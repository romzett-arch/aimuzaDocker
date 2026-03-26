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

function getVideoUrl(payload: Record<string, any>): string | null {
  return payload?.data?.video_url
    ?? payload?.data?.videoUrl
    ?? payload?.data?.data?.[0]?.video_url
    ?? payload?.data?.data?.[0]?.mp4_url
    ?? null;
}

function getMusicId(payload: Record<string, any>): string | null {
  return payload?.data?.musicId
    ?? payload?.data?.music_id
    ?? payload?.data?.data?.[0]?.id
    ?? payload?.musicId
    ?? payload?.music_id
    ?? null;
}

function parseAddonState(rawValue: unknown): {
  video_task_id?: string;
  suno_audio_id?: string;
} | null {
  if (!rawValue) return null;

  if (typeof rawValue === "object") {
    return rawValue as {
      video_task_id?: string;
      suno_audio_id?: string;
    };
  }

  if (typeof rawValue !== "string" || !rawValue.trim()) return null;

  try {
    return JSON.parse(rawValue) as {
      video_task_id?: string;
      suno_audio_id?: string;
    };
  } catch {
    return null;
  }
}

function normalizeTrackData(rawValue: unknown): {
  id: string;
  user_id: string;
  title: string;
  suno_audio_id: string | null;
} | null {
  if (!rawValue) return null;

  const candidate = Array.isArray(rawValue) ? rawValue[0] : rawValue;
  if (!candidate || typeof candidate !== "object") return null;

  const track = candidate as Record<string, unknown>;
  if (typeof track.id !== "string" || typeof track.user_id !== "string") {
    return null;
  }

  return {
    id: track.id,
    user_id: track.user_id,
    title: typeof track.title === "string" ? track.title : "Трек",
    suno_audio_id: typeof track.suno_audio_id === "string" ? track.suno_audio_id : null,
  };
}

async function refundMusicVideo(
  supabase: ReturnType<typeof createClient>,
  trackId: string,
  userId: string,
  reason: string,
): Promise<void> {
  const { data: service } = await supabase
    .from("addon_services")
    .select("price_rub")
    .eq("name", "short_video")
    .single();

  if (!service?.price_rub) return;

  await supabase.rpc("refund_generation_failed", {
    p_user_id: userId,
    p_amount: service.price_rub,
    p_track_id: trackId,
    p_description: `Возврат за ошибку генерации музыкального видео: ${reason}`,
  });
}

async function resumeReleasePackageBuild(trackId: string): Promise<void> {
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
    console.log(`[video-cb] release-package resume ${response.status}: ${payload}`);
  } catch (error) {
    console.error("[video-cb] release-package resume failed:", error);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const body = await req.json();
    console.log("Suno video callback received:", JSON.stringify(body));

    const { code, msg, data } = body;
    const task_id = getTaskId(body);
    const video_url = getVideoUrl(body);
    let musicId = getMusicId(body);
    
    // Determine callback type from response structure
    let callbackType = data?.callbackType;
    if (!callbackType && video_url) {
      callbackType = "complete"; // If we have video_url, it's complete
    }
    console.log(`Video callback type: ${callbackType}, task_id: ${task_id}`);

    // Find the track addon with this video task ID
    // The result_url field contains JSON with video_task_id
    const { data: addonService, error: addonServiceError } = await supabase
      .from("addon_services")
      .select("id")
      .eq("name", "short_video")
      .single();

    if (addonServiceError || !addonService?.id) {
      console.error("short_video addon service not found:", addonServiceError);
      return new Response(JSON.stringify({ received: true, error: "Addon service not found" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: addons, error: findError } = await supabase
      .from("track_addons")
      .select("id, track_id, user_id, addon_service_id, status, result_url, tracks!inner(id, user_id, title, suno_audio_id)")
      .eq("addon_service_id", addonService.id)
      .in("status", ["processing", "completed"]);

    if (findError) {
      console.error("Error finding addons:", findError);
      return new Response(JSON.stringify({ received: true, error: "Error finding addon" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Find the addon that matches this video task_id
    let matchedAddon = null;
    for (const addon of addons || []) {
      const resultData = parseAddonState(addon.result_url);
      const rawResult = typeof addon.result_url === "string" ? addon.result_url : JSON.stringify(addon.result_url ?? {});
      if (resultData?.video_task_id === task_id || (task_id && rawResult.includes(task_id))) {
        matchedAddon = addon;
        break;
      }
    }

    if (!matchedAddon) {
      if (!musicId && task_id) {
        const sunoApiKey = Deno.env.get("SUNO_API_KEY");
        if (sunoApiKey) {
          try {
            const infoResponse = await fetch(
              `https://api.sunoapi.org/api/v1/mp4/record-info?taskId=${encodeURIComponent(task_id)}`,
              { headers: { Authorization: `Bearer ${sunoApiKey}` } },
            );
            const infoPayload = await infoResponse.json().catch(() => ({}));
            musicId = getMusicId(infoPayload);
          } catch (lookupError) {
            console.error("Failed to resolve callback musicId:", lookupError);
          }
        }
      }

      if (musicId) {
        for (const addon of addons || []) {
          const resultData = parseAddonState(addon.result_url);
          const trackData = normalizeTrackData(addon.tracks);
          const addonAudioId = resultData?.suno_audio_id ?? trackData?.suno_audio_id ?? null;
          if (addonAudioId === musicId) {
            matchedAddon = addon;
            console.log(`Matched video callback by musicId ${musicId} for addon ${addon.id}`);
            break;
          }
        }
      }
    }

    if (!matchedAddon) {
      console.log("No matching addon found for video task_id:", task_id, "musicId:", musicId);
      return new Response(JSON.stringify({ received: true, message: "No matching addon" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const trackData = normalizeTrackData(matchedAddon.tracks);
    if (!trackData) {
      throw new Error(`track_relation_missing_for_addon:${matchedAddon.id}`);
    }
    const trackId = trackData.id;
    const userId = trackData.user_id;
    const trackTitle = trackData.title;

    console.log(`Found addon ${matchedAddon.id} for track ${trackId}`);

    if (callbackType === "complete" || callbackType === "SUCCESS") {
      // Video generation completed - use video_url from data directly
      const finalVideoUrl = video_url || data?.data?.[0]?.video_url || data?.data?.[0]?.mp4_url;

      console.log(`Video completed for track ${trackId}, URL: ${finalVideoUrl}`);

      const { error: updateError } = await supabase
        .from("track_addons")
        .update({
          status: "completed",
          result_url: finalVideoUrl || JSON.stringify(data),
          updated_at: new Date().toISOString(),
        })
        .eq("id", matchedAddon.id);

      if (updateError) {
        console.error("Error updating addon:", updateError);
      }

      const { data: pendingReleasePackage } = await supabase
        .from("release_packages")
        .select("id")
        .eq("track_id", trackId)
        .eq("status", "processing")
        .maybeSingle();

      if (pendingReleasePackage?.id) {
        await resumeReleasePackageBuild(trackId);
      }

      // Create notification for user
      await supabase.from("notifications").insert({
        user_id: userId,
        type: "addon_completed",
        title: "Музыкальное видео готово",
        message: `Видео для трека "${trackTitle}" успешно создано`,
        target_type: "track",
        target_id: trackId,
      });

    } else if (callbackType === "FAILED" || callbackType === "error") {
      // Video generation failed
      console.error(`Video generation failed for track ${trackId}: ${msg}`);

      const { error: updateError } = await supabase
        .from("track_addons")
        .update({
          status: "failed",
          result_url: JSON.stringify({ error: msg || "Video generation failed" }),
          updated_at: new Date().toISOString(),
        })
        .eq("id", matchedAddon.id);

      if (updateError) {
        console.error("Error updating addon:", updateError);
      }

      await refundMusicVideo(supabase, trackId, userId, msg || "Video generation failed");

      // Create notification for user
      await supabase.from("notifications").insert({
        user_id: userId,
        type: "addon_failed",
        title: "Ошибка создания видео",
        message: `Не удалось создать видео для трека "${trackTitle}"`,
        target_type: "track",
        target_id: trackId,
      });
    } else if (code !== 200) {
      console.error(`Suno video callback error for track ${trackId}: ${msg}`);

      await supabase
        .from("track_addons")
        .update({
          status: "failed",
          result_url: JSON.stringify({ error: msg || "Video generation failed" }),
          updated_at: new Date().toISOString(),
        })
        .eq("id", matchedAddon.id);

      await refundMusicVideo(supabase, trackId, userId, msg || "Video generation failed");
    }

    return new Response(
      JSON.stringify({ received: true, success: true }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("suno-video-callback error:", error);
    return new Response(
      JSON.stringify({
        received: true,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
