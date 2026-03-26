import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./constants.ts";
import { validateAuth, AuthError } from "./auth.ts";
import { copyWavToStorage, processWavViaFfmpeg } from "./utils.ts";

async function fetchReadyWavUrl(taskId: string, apiKey: string): Promise<string | null> {
  const statusResponse = await fetch(
    `https://api.sunoapi.org/api/v1/wav/record-info?taskId=${taskId}`,
    { headers: { "Authorization": `Bearer ${apiKey}` } }
  );

  const statusResult = await statusResponse.json();
  console.log("WAV record-info response:", statusResult);

  if (statusResult.code !== 200) {
    return null;
  }

  return statusResult.data?.response?.audioWavUrl
    ?? statusResult.data?.response?.audio_wav_url
    ?? statusResult.data?.audioWavUrl
    ?? statusResult.data?.audio_wav_url
    ?? null;
}

function getResponseTaskId(result: Record<string, any>): string | null {
  return result?.data?.taskId
    ?? result?.data?.task_id
    ?? result?.taskId
    ?? result?.task_id
    ?? null;
}

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

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  let refundOnError: { userId: string; trackId: string; amount: number } | null = null;

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
    const ffmpegPublicUrl = Deno.env.get("FFMPEG_PUBLIC_URL");

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, suno_audio_id, title, description, audio_url, performer_name, label_name")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    if (!isInternalCall && track.user_id !== userId) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id, price_rub")
      .eq("name", "convert_wav")
      .single();

    if (!addonService) {
      throw new Error("WAV conversion service not found");
    }

    const markAddonFailed = async (addonId?: string) => {
      if (!addonId) return;
      await supabase.from("track_addons").update({
        status: "failed",
        updated_at: new Date().toISOString(),
      }).eq("id", addonId);
    };

    const finalizeWavAddon = async (originalWavUrl: string, addonId?: string) => {
      const { data: profile } = await supabase
        .from("profiles")
        .select("username, display_name, short_id")
        .eq("user_id", track.user_id)
        .single();
      const artistName = track.performer_name || profile?.display_name || profile?.username || "AIMuza Artist";
      const publisherName = track.label_name || "AIMuza";
      const cabinetId = profile?.short_id || track.user_id;

      if (!ffmpegApiUrl || !ffmpegApiSecret) {
        await markAddonFailed(addonId);
        throw new Error("FFmpeg WAV processing unavailable");
      }

      const finalWavUrl = await processWavViaFfmpeg(
        originalWavUrl,
        track.title,
        artistName,
        publisherName,
        cabinetId,
        ffmpegApiUrl,
        ffmpegApiSecret,
        ffmpegPublicUrl ?? undefined,
      );

      if (!finalWavUrl) {
        await markAddonFailed(addonId);
        throw new Error("FFmpeg WAV processing failed");
      }

      const stableWavUrl = await copyWavToStorage(supabase, finalWavUrl, track_id);
      if (!stableWavUrl) {
        await markAddonFailed(addonId);
        throw new Error("Failed to persist WAV to storage");
      }

      await persistAddonState(supabase, {
        trackId: track_id,
        userId: track.user_id,
        addonServiceId: addonService.id,
        status: "completed",
        resultUrl: stableWavUrl,
      });

      return stableWavUrl;
    };

    // Проверяем существующий addon — не списываем повторно если уже processing/completed
    const { data: existingAddon } = await supabase
      .from("track_addons")
      .select("id, status, result_url")
      .eq("track_id", track_id)
      .eq("addon_service_id", addonService.id)
      .maybeSingle();

    if (existingAddon?.status === "completed" && existingAddon.result_url) {
      console.log("WAV addon already completed:", existingAddon.result_url);
      return new Response(
        JSON.stringify({ success: true, wav_url: existingAddon.result_url, message: "WAV already available" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (existingAddon?.status === "processing") {
      let existingTaskId: string | null = null;
      if (existingAddon.result_url) {
        try {
          const parsedResult = JSON.parse(existingAddon.result_url);
          existingTaskId = parsedResult?.wav_task_id ?? null;
        } catch (parseError) {
          console.warn("Failed to parse existing WAV addon result_url:", parseError);
        }
      }

      if (existingTaskId) {
        console.log(`WAV conversion marked as processing, checking taskId=${existingTaskId}`);
        const readyWavUrl = await fetchReadyWavUrl(existingTaskId, SUNO_API_KEY);
        if (readyWavUrl) {
          const finalWavUrl = await finalizeWavAddon(readyWavUrl, existingAddon.id);
          return new Response(
            JSON.stringify({ success: true, wav_url: finalWavUrl, message: "WAV ready" }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
      }

      console.log("WAV conversion already in progress");
      return new Response(
        JSON.stringify({ success: true, message: "WAV conversion already in progress" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
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

    const price = addonService.price_rub ?? 5;
    if (!isInternalCall && userId && price > 0) {
      const { data: profileData, error: profileError } = await supabase
        .from("profiles")
        .select("balance")
        .eq("user_id", track.user_id)
        .single();

      if (profileError || !profileData) {
        return new Response(
          JSON.stringify({ error: "Ошибка получения баланса" }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const currentBalance = profileData.balance ?? 0;
      if (currentBalance < price) {
        return new Response(
          JSON.stringify({ error: "Недостаточно средств" }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
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
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      await supabase.from("balance_transactions").insert({
        user_id: track.user_id,
        amount: -price,
        type: "addon_service",
        description: "Конвертация в WAV",
        balance_before: currentBalance,
        balance_after: newBalance,
      });

      refundOnError = { userId: track.user_id, trackId: track_id, amount: price };
    }

    const callbackUrl = `${Deno.env.get("BASE_URL") || "https://aimuza.ru"}/functions/v1/wav-callback`;

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
    const responseTaskId = getResponseTaskId(result);

    // WAV уже был создан ранее — забираем по record-info
    if (result.code === 409 && responseTaskId) {
      console.log("WAV already exists at Suno, fetching record-info...");

      const readyWavUrl = await fetchReadyWavUrl(responseTaskId, SUNO_API_KEY);
      if (readyWavUrl) {
        const finalWavUrl = await finalizeWavAddon(readyWavUrl);

        return new Response(
          JSON.stringify({ success: true, wav_url: finalWavUrl, message: "WAV ready" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // WAV у Suno ещё в обработке
      await persistAddonState(supabase, {
        trackId: track_id,
        userId: track.user_id,
        addonServiceId: addonService.id,
        status: "processing",
        resultUrl: JSON.stringify({ wav_task_id: responseTaskId, suno_audio_id: audioId }),
      });

      return new Response(
        JSON.stringify({ success: true, taskId: responseTaskId, message: "WAV conversion in progress" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (result.code !== 200) {
      throw new Error(result.msg || "Failed to start WAV conversion");
    }

    await persistAddonState(supabase, {
      trackId: track_id,
      userId: track.user_id,
      addonServiceId: addonService.id,
      status: "processing",
      resultUrl: JSON.stringify({ wav_task_id: responseTaskId, suno_audio_id: audioId }),
    });

    return new Response(
      JSON.stringify({ success: true, taskId: responseTaskId }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in convert-to-wav:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    if (refundOnError && refundOnError.amount > 0) {
      const supabaseRefund = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
      );
      try {
        await supabaseRefund.rpc("refund_generation_failed", {
          p_user_id: refundOnError.userId,
          p_amount: refundOnError.amount,
          p_track_id: refundOnError.trackId,
          p_description: `Возврат за ошибку конвертации в WAV: ${message}`,
        });
        console.log(`Refunded ${refundOnError.amount} ₽ for failed WAV conversion`);
      } catch (refundErr) {
        console.error("Refund failed:", refundErr);
      }
    }
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
