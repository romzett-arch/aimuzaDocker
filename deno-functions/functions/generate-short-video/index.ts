import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./constants.ts";
import { validateAuth, AuthError } from "./auth.ts";
import { refundUser } from "./refund.ts";
import { handleVideoAlreadyExists } from "./handleVideoExists.ts";

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
    const { track_id, suno_task_id, suno_audio_id, author } = body;

    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY is not configured");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    console.log(`Generating music video for track: ${track_id}, suno_task_id: ${suno_task_id}, suno_audio_id: ${suno_audio_id}`);

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, suno_audio_id, title, description")
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

    const audioId = suno_audio_id || track.suno_audio_id;

    let taskId = suno_task_id;
    if (!taskId && track.description) {
      const taskIdMatch = track.description.match(/\[task_id:\s*([^\]]+)\]/);
      if (taskIdMatch) {
        taskId = taskIdMatch[1].trim();
        console.log(`Extracted task_id from description: ${taskId}`);
      }
    }

    if (!taskId) {
      throw new Error("Track has no Suno task ID for video generation");
    }

    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id, price_rub")
      .eq("name", "short_video")
      .single();

    if (!addonService) {
      throw new Error("Video addon service not found");
    }

    const price = addonService.price_rub;

    if (!isInternalCall && userId) {
      const { data: profile, error: profileError } = await supabase
        .from("profiles")
        .select("balance")
        .eq("user_id", userId)
        .single();

      if (profileError || !profile) {
        throw new Error("User profile not found");
      }

      if ((profile.balance || 0) < price) {
        return new Response(
          JSON.stringify({ error: "Insufficient balance", required: price, current: profile.balance }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const newBalance = (profile.balance || 0) - price;
      const { error: deductError } = await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", userId);

      if (deductError) {
        throw new Error("Failed to deduct balance");
      }

      await supabase.from("balance_transactions").insert({
        user_id: userId,
        amount: -price,
        balance_after: newBalance,
        type: "video",
        description: "Промо-видео",
        reference_id: track_id,
        reference_type: "track",
      });

      await supabase
        .from("track_addons")
        .insert({
          track_id: track_id,
          addon_service_id: addonService.id,
          status: "processing",
          result_url: JSON.stringify({ status: "starting" }),
        });
    }

    const callbackUrl = `${supabaseUrl}/functions/v1/suno-video-callback`;

    const requestBody: Record<string, unknown> = {
      callBackUrl: callbackUrl,
      taskId: taskId,
    };

    if (audioId) {
      requestBody.audioId = audioId;
    }

    if (author) {
      requestBody.author = author;
    }

    console.log("Requesting Suno music video:", JSON.stringify(requestBody));

    const response = await fetch("https://api.sunoapi.org/api/v1/mp4/generate", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${SUNO_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
    });

    const responseText = await response.text();
    console.log("Suno video response:", response.status, responseText);

    let data;
    try {
      data = JSON.parse(responseText);
    } catch {
      throw new Error(`Invalid JSON response from Suno: ${responseText}`);
    }

    if (data.code !== 200 && data.msg?.includes("Mp4 record already exists")) {
      console.log("Video already exists, fetching status...");
      return await handleVideoAlreadyExists({
        taskId,
        trackId: track_id,
        addonServiceId: addonService.id,
        price,
        sunoApiKey: SUNO_API_KEY,
        supabase,
        userId,
        isInternalCall,
      });
    }

    if (!response.ok) {
      if (!isInternalCall && userId) {
        await refundUser(supabase, userId, price);
        await supabase
          .from("track_addons")
          .update({ status: "failed", result_url: JSON.stringify({ error: "Suno API error" }) })
          .eq("track_id", track_id)
          .eq("addon_service_id", addonService.id);
      }
      throw new Error(`Suno API error: ${response.status} - ${responseText}`);
    }

    if (data.code !== 200) {
      if (!isInternalCall && userId) {
        await refundUser(supabase, userId, price);
        await supabase
          .from("track_addons")
          .update({ status: "failed", result_url: JSON.stringify({ error: data.msg }) })
          .eq("track_id", track_id)
          .eq("addon_service_id", addonService.id);
      }
      throw new Error(`Suno API error: ${data.msg || "Unknown error"}`);
    }

    const videoTaskId = data.data?.taskId;
    if (!videoTaskId) {
      throw new Error("No video taskId received from Suno");
    }

    console.log(`Video generation started, Suno video task ID: ${videoTaskId}`);

    const { error: updateError } = await supabase
      .from("track_addons")
      .update({
        status: "processing",
        result_url: JSON.stringify({
          video_task_id: videoTaskId,
          track_id: track_id,
          suno_audio_id: audioId || null,
          status: "processing"
        }),
        updated_at: new Date().toISOString(),
      })
      .eq("track_id", track_id)
      .eq("addon_service_id", addonService.id);

    if (updateError) {
      console.error("Update addon error:", updateError);
    }

    return new Response(
      JSON.stringify({
        success: true,
        video_task_id: videoTaskId,
        message: "Music video generation started",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("generate-short-video error:", error);

    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
