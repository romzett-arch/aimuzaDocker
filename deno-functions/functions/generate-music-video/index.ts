import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

function getTaskIdFromDescription(description: string | null | undefined): string | null {
  if (!description) return null;
  const match = description.match(/\[task_id:\s*([^\]]+)\]/i);
  return match?.[1]?.trim() || null;
}

function getResponseTaskId(payload: Record<string, any>): string | null {
  return payload?.data?.taskId
    ?? payload?.data?.task_id
    ?? payload?.taskId
    ?? payload?.task_id
    ?? null;
}

function getReadyVideoUrl(payload: Record<string, any>): string | null {
  return payload?.data?.response?.videoUrl
    ?? payload?.data?.response?.video_url
    ?? payload?.data?.videoUrl
    ?? payload?.data?.video_url
    ?? null;
}

function getStoredVideoTaskId(rawValue: string | null | undefined): string | null {
  if (!rawValue) return null;

  try {
    const parsed = JSON.parse(rawValue) as {
      video_task_id?: string;
      task_id?: string;
      taskId?: string;
    };

    return parsed.video_task_id ?? parsed.task_id ?? parsed.taskId ?? null;
  } catch {
    return null;
  }
}

const TERMINAL_VIDEO_FAILURE_FLAGS = new Set([
  "FAILED",
  "FAIL",
  "ERROR",
  "CANCELLED",
  "CANCELED",
  "REJECTED",
]);

type VideoTaskState =
  | { status: "completed"; videoUrl: string }
  | { status: "failed"; errorMessage: string }
  | { status: "processing" };

async function persistAddonState(
  supabase: ReturnType<typeof createClient>,
  params: {
    trackId: string;
    userId: string;
    addonServiceId: string;
    status: string;
    resultUrl: string;
  },
): Promise<string> {
  const { trackId, userId, addonServiceId, status, resultUrl } = params;

  const { data: existingAddon, error: existingAddonError } = await supabase
    .from("track_addons")
    .select("id")
    .eq("track_id", trackId)
    .eq("addon_service_id", addonServiceId)
    .maybeSingle();

  if (existingAddonError) {
    throw new Error(`track_addons_lookup_failed: ${existingAddonError.message}`);
  }

  if (existingAddon?.id) {
    const { error: updateError } = await supabase
      .from("track_addons")
      .update({
        user_id: userId,
        status,
        result_url: resultUrl,
        updated_at: new Date().toISOString(),
      })
      .eq("id", existingAddon.id);

    if (updateError) {
      throw new Error(`track_addons_update_failed: ${updateError.message}`);
    }

    return existingAddon.id;
  }

  const { data: insertedAddon, error: insertError } = await supabase
    .from("track_addons")
    .insert({
      track_id: trackId,
      user_id: userId,
      addon_service_id: addonServiceId,
      status,
      result_url: resultUrl,
      updated_at: new Date().toISOString(),
    })
    .select("id")
    .single();

  if (insertError || !insertedAddon?.id) {
    throw new Error(`track_addons_insert_failed: ${insertError?.message || "missing_inserted_id"}`);
  }

  return insertedAddon.id;
}

async function fetchVideoTaskState(taskId: string, apiKey: string): Promise<VideoTaskState> {
  const response = await fetch(
    `https://api.sunoapi.org/api/v1/mp4/record-info?taskId=${encodeURIComponent(taskId)}`,
    { headers: { Authorization: `Bearer ${apiKey}` } },
  );

  const result = await response.json().catch(() => ({}));
  if (!response.ok || result?.code !== 200) {
    return { status: "processing" };
  }

  if (!result?.data) {
    return { status: "processing" };
  }

  const successFlag = String(result?.data?.successFlag || "").toUpperCase();
  const readyVideoUrl = getReadyVideoUrl(result);
  if (readyVideoUrl) {
    return { status: "completed", videoUrl: readyVideoUrl };
  }

  if (successFlag && TERMINAL_VIDEO_FAILURE_FLAGS.has(successFlag)) {
    return {
      status: "failed",
      errorMessage: result?.data?.errorMessage || result?.data?.errorCode || "Music video generation failed",
    };
  }

  if (result?.data?.errorMessage) {
    return {
      status: "failed",
      errorMessage: result.data.errorMessage,
    };
  }

  return { status: "processing" };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
  const supabase = createClient(supabaseUrl, supabaseServiceKey);
  let refundOnError: { userId: string; trackId: string; amount: number } | null = null;
  let isInternalCall = false;

  try {
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    let user: { id: string } | null = null;
    if (authHeader === `Bearer ${supabaseServiceKey}`) {
      isInternalCall = true;
    } else {
      const userClient = createClient(supabaseUrl, supabaseAnonKey, {
        global: { headers: { Authorization: authHeader } },
      });
      const {
        data: { user: authUser },
        error: userError,
      } = await userClient.auth.getUser();

      if (userError || !authUser) {
        return new Response(
          JSON.stringify({ error: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      user = authUser;
    }

    const body = await req.json().catch(() => ({}));
    const trackId = typeof body?.track_id === "string" ? body.track_id : "";
    const author = typeof body?.author === "string" ? body.author.trim().slice(0, 50) : "";
    const domainName = typeof body?.domainName === "string" ? body.domainName.trim().slice(0, 50) : "aimuza.ru";

    if (!trackId) {
      throw new Error("track_id is required");
    }

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, title, description, audio_url, status, source_type, suno_audio_id, performer_name")
      .eq("id", trackId)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    if (!isInternalCall && track.user_id !== user?.id) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if ((track.source_type || "generated") !== "generated") {
      throw new Error("Music video is available only for generated tracks");
    }

    if (track.status !== "completed" || !track.audio_url) {
      throw new Error("Track is not ready for music video generation");
    }

    const { data: addonService, error: addonError } = await supabase
      .from("addon_services")
      .select("id, price_rub, is_active")
      .eq("name", "short_video")
      .single();

    if (addonError || !addonService?.id || !addonService.is_active) {
      throw new Error("Music video service is unavailable");
    }

    const { data: existingAddon } = await supabase
      .from("track_addons")
      .select("id, status, result_url")
      .eq("track_id", trackId)
      .eq("addon_service_id", addonService.id)
      .maybeSingle();

    const existingReadyUrl = typeof existingAddon?.result_url === "string" && existingAddon.result_url.startsWith("http")
      ? existingAddon.result_url
      : null;

    if (existingAddon?.status === "completed" && existingReadyUrl) {
      return new Response(
        JSON.stringify({ success: true, video_url: existingReadyUrl, message: "Music video already available" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const taskId = getTaskIdFromDescription(track.description);
    let audioId = track.suno_audio_id;

    if (!taskId) {
      throw new Error("Track has no Suno task ID for music video generation");
    }

    if (!audioId) {
      try {
        const infoResp = await fetch(
          `https://apibox.erweima.ai/api/v1/generate/record-info?taskId=${encodeURIComponent(taskId)}`,
          { headers: { Authorization: `Bearer ${SUNO_API_KEY}` } },
        );
        const infoData = await infoResp.json().catch(() => ({}));
        const sunoRecords = infoData?.data?.response?.sunoData;
        const titleSuffix = track.title?.match(/\(v(\d+)\)/)?.[1];
        const idx = titleSuffix ? parseInt(titleSuffix, 10) - 1 : 0;
        const matched = Array.isArray(sunoRecords) ? (sunoRecords[idx] || sunoRecords[0]) : null;
        if (matched?.id) {
          audioId = matched.id;
          await supabase.from("tracks").update({ suno_audio_id: audioId }).eq("id", trackId);
        }
      } catch (lookupError) {
        console.error("Failed to resolve suno_audio_id for music video:", lookupError);
      }
    }

    if (!audioId) {
      throw new Error("Track has no Suno audio ID and could not resolve it");
    }

    const existingVideoTaskId = getStoredVideoTaskId(existingAddon?.result_url);

    if (existingVideoTaskId && existingAddon?.status !== "completed") {
      const taskState = await fetchVideoTaskState(existingVideoTaskId, SUNO_API_KEY);

      if (taskState.status === "completed") {
        await persistAddonState(supabase, {
          trackId,
          userId: track.user_id,
          addonServiceId: addonService.id,
          status: "completed",
          resultUrl: taskState.videoUrl,
        });

        return new Response(
          JSON.stringify({ success: true, video_url: taskState.videoUrl, message: "Music video ready" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (taskState.status === "processing") {
        if (existingAddon.status !== "processing") {
          await persistAddonState(supabase, {
            trackId,
            userId: track.user_id,
            addonServiceId: addonService.id,
            status: "processing",
            resultUrl: JSON.stringify({ video_task_id: existingVideoTaskId, suno_audio_id: audioId }),
          });
        }

        return new Response(
          JSON.stringify({ success: true, taskId: existingVideoTaskId, message: "Music video generation already in progress" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    if (existingAddon?.status === "processing") {
      const existingTaskId = existingVideoTaskId || taskId;
      const taskState = await fetchVideoTaskState(existingTaskId, SUNO_API_KEY);

      if (taskState.status === "completed") {
        await persistAddonState(supabase, {
          trackId,
          userId: track.user_id,
          addonServiceId: addonService.id,
          status: "completed",
          resultUrl: taskState.videoUrl,
        });

        return new Response(
          JSON.stringify({ success: true, video_url: taskState.videoUrl, message: "Music video ready" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (taskState.status === "failed") {
        await persistAddonState(supabase, {
          trackId,
          userId: track.user_id,
          addonServiceId: addonService.id,
          status: "failed",
          resultUrl: JSON.stringify({ error: taskState.errorMessage, video_task_id: existingTaskId }),
        });

        return new Response(
          JSON.stringify({ error: taskState.errorMessage }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      return new Response(
        JSON.stringify({ success: true, taskId: existingTaskId, message: "Music video generation already in progress" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (!isInternalCall) {
      const { data: tierData, error: tierError } = await supabase.rpc("get_user_subscription_tier" as never, {
        p_user_id: user?.id,
      });

      if (tierError) {
        throw new Error(`subscription_check_failed:${tierError.message}`);
      }

      if ((tierData as { tier_key?: string } | null)?.tier_key === "free") {
        return new Response(
          JSON.stringify({ error: "music_video_requires_paid_tier" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const price = addonService.price_rub ?? 12;
      if (price > 0) {
        const { data: profileData, error: profileError } = await supabase
          .from("profiles")
          .select("balance")
          .eq("user_id", track.user_id)
          .single();

        if (profileError || !profileData) {
          return new Response(
            JSON.stringify({ error: "Ошибка получения баланса" }),
            { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }

        const currentBalance = profileData.balance ?? 0;
        if (currentBalance < price) {
          return new Response(
            JSON.stringify({ error: "Недостаточно средств" }),
            { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }

        const newBalance = currentBalance - price;
        const { error: updateError } = await supabase
          .from("profiles")
          .update({ balance: newBalance })
          .eq("user_id", track.user_id)
          .gte("balance", price);

        if (updateError) {
          return new Response(
            JSON.stringify({ error: "Ошибка списания баланса" }),
            { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }

        await supabase.from("balance_transactions").insert({
          user_id: track.user_id,
          amount: -price,
          type: "addon_service",
          description: "Музыкальное видео Suno",
          balance_before: currentBalance,
          balance_after: newBalance,
          metadata: {
            track_id: trackId,
            addon_name: "short_video",
          },
        });

        refundOnError = { userId: track.user_id, trackId, amount: price };
      }
    }

    const callbackUrl = `${Deno.env.get("BASE_URL") || "https://aimuza.ru"}/functions/v1/suno-video-callback`;
    const response = await fetch("https://api.sunoapi.org/api/v1/mp4/generate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify({
        taskId,
        audioId,
        callBackUrl: callbackUrl,
        author: author || track.performer_name || "AIMuza Artist",
        domainName,
      }),
    });

    const result = await response.json().catch(() => ({}));
    const responseTaskId = getResponseTaskId(result) || taskId;

    if (result?.code === 409 && responseTaskId) {
      const taskState = await fetchVideoTaskState(responseTaskId, SUNO_API_KEY);
      if (taskState.status === "completed") {
        await persistAddonState(supabase, {
          trackId,
          userId: track.user_id,
          addonServiceId: addonService.id,
          status: "completed",
          resultUrl: taskState.videoUrl,
        });

        return new Response(
          JSON.stringify({ success: true, video_url: taskState.videoUrl, message: "Music video ready" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (taskState.status === "failed") {
        throw new Error(taskState.errorMessage);
      }

      await persistAddonState(supabase, {
        trackId,
        userId: track.user_id,
        addonServiceId: addonService.id,
        status: "processing",
        resultUrl: JSON.stringify({ video_task_id: responseTaskId, suno_audio_id: audioId }),
      });

      return new Response(
        JSON.stringify({ success: true, taskId: responseTaskId, message: "Music video generation in progress" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (result?.code !== 200) {
      throw new Error(result?.msg || "Failed to start music video generation");
    }

    await persistAddonState(supabase, {
      trackId,
      userId: track.user_id,
      addonServiceId: addonService.id,
      status: "processing",
      resultUrl: JSON.stringify({ video_task_id: responseTaskId, suno_audio_id: audioId }),
    });

    return new Response(
      JSON.stringify({ success: true, taskId: responseTaskId }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("Error in generate-music-video:", message);

    if (refundOnError?.amount) {
      try {
        const refundClient = createClient(supabaseUrl, supabaseServiceKey);
        await refundClient.rpc("refund_generation_failed", {
          p_user_id: refundOnError.userId,
          p_amount: refundOnError.amount,
          p_track_id: refundOnError.trackId,
          p_description: `Возврат за ошибку генерации музыкального видео: ${message}`,
        });
      } catch (refundError) {
        console.error("Music video refund failed:", refundError);
      }
    }

    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
