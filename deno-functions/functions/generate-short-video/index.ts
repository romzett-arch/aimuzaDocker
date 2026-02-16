import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  try {
    const authHeader = req.headers.get("Authorization");
    let userId: string | null = null;
    let isInternalCall = false;

    // Check if this is an internal call (from suno-callback) with service key
    if (authHeader === `Bearer ${supabaseServiceKey}`) {
      isInternalCall = true;
      console.log("Internal service call detected");
    } else if (authHeader?.startsWith("Bearer ")) {
      // User JWT - validate and get user
      const userClient = createClient(supabaseUrl, supabaseAnonKey, {
        global: { headers: { Authorization: authHeader } }
      });
      
      const token = authHeader.replace("Bearer ", "");
      const { data: claimsData, error: claimsError } = await userClient.auth.getClaims(token);
      
      if (claimsError || !claimsData?.claims) {
        return new Response(
          JSON.stringify({ error: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      userId = claimsData.claims.sub as string;
      console.log(`User call from: ${userId}`);
    } else {
      return new Response(
        JSON.stringify({ error: "Unauthorized - missing auth" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();
    const { track_id, suno_task_id, suno_audio_id, author } = body;
    
    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY is not configured");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    console.log(`Generating music video for track: ${track_id}, suno_task_id: ${suno_task_id}, suno_audio_id: ${suno_audio_id}`);

    // Get track info to verify ownership and get suno_audio_id if not provided
    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, suno_audio_id, title, description")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    // If user call, verify ownership
    if (!isInternalCall && track.user_id !== userId) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Use provided suno_audio_id or get from track
    const audioId = suno_audio_id || track.suno_audio_id;
    
    // Extract task_id from track description (format: [task_id: xxx])
    let taskId = suno_task_id;
    if (!taskId && track.description) {
      const taskIdMatch = track.description.match(/\[task_id:\s*([^\]]+)\]/);
      if (taskIdMatch) {
        taskId = taskIdMatch[1].trim();
        console.log(`Extracted task_id from description: ${taskId}`);
      }
    }

    // Validate we have required parameters - Suno API requires taskId
    if (!taskId) {
      throw new Error("Track has no Suno task ID for video generation");
    }

    // Get addon service price
    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id, price_rub")
      .eq("name", "short_video")
      .single();

    if (!addonService) {
      throw new Error("Video addon service not found");
    }

    const price = addonService.price_rub;

    // If user call (not internal from addon processing), check balance and deduct
    if (!isInternalCall && userId) {
      // Check user balance
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

      // Deduct balance
      const newBalance = (profile.balance || 0) - price;
      const { error: deductError } = await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", userId);

      if (deductError) {
        throw new Error("Failed to deduct balance");
      }

      // Log transaction
      await supabase.from("balance_transactions").insert({
        user_id: userId,
        amount: -price,
        balance_after: newBalance,
        type: "video",
        description: "Промо-видео",
        reference_id: track_id,
        reference_type: "track",
      });

      // Create track_addon record
      await supabase
        .from("track_addons")
        .insert({
          track_id: track_id,
          addon_service_id: addonService.id,
          status: "processing",
          result_url: JSON.stringify({ status: "starting" }),
        });
    }

    // Build callback URL for Suno
    const callbackUrl = `${supabaseUrl}/functions/v1/suno-video-callback`;

    // Request music video generation from Suno API
    // According to Suno docs, both taskId and audioId can be provided
    // taskId is required, audioId is optional but more specific
    const requestBody: Record<string, unknown> = {
      callBackUrl: callbackUrl,
      taskId: taskId, // Required
    };

    // Add audioId if available (more specific)
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

    // Handle "Mp4 record already exists" - means video is already generated
    // Try to fetch the existing video URL
    if (data.code !== 200 && data.msg?.includes("Mp4 record already exists")) {
      console.log("Video already exists, fetching status...");
      
      // Try to get existing video via status API
      const statusResponse = await fetch(`https://api.sunoapi.org/api/v1/mp4/query?taskId=${taskId}`, {
        method: "GET",
        headers: {
          "Authorization": `Bearer ${SUNO_API_KEY}`,
          "Content-Type": "application/json",
        },
      });
      
      const statusText = await statusResponse.text();
      console.log("Suno video status response:", statusResponse.status, statusText);
      
      let statusData;
      try {
        statusData = JSON.parse(statusText);
      } catch {
        // If status API fails, refund and error
        if (!isInternalCall && userId) {
          const { data: currentProfile } = await supabase
            .from("profiles")
            .select("balance")
            .eq("user_id", userId)
            .single();
          
          await supabase
            .from("profiles")
            .update({ balance: (currentProfile?.balance || 0) + price })
            .eq("user_id", userId);
        }
        throw new Error("Video already exists but failed to fetch URL");
      }
      
      if (statusData.code === 200 && statusData.data) {
        // Video exists - extract URL
        const videoUrl = statusData.data.video_url || statusData.data.mp4_url || statusData.data.url;
        
        if (videoUrl) {
          console.log(`Found existing video: ${videoUrl}`);
          
          // Refund user since video already exists
          if (!isInternalCall && userId) {
            const { data: currentProfile } = await supabase
              .from("profiles")
              .select("balance")
              .eq("user_id", userId)
              .single();
            
            await supabase
              .from("profiles")
              .update({ balance: (currentProfile?.balance || 0) + price })
              .eq("user_id", userId);
          }
          
          // Update addon to completed with existing URL
          await supabase
            .from("track_addons")
            .update({ 
              status: "completed", 
              result_url: videoUrl,
              updated_at: new Date().toISOString()
            })
            .eq("track_id", track_id)
            .eq("addon_service_id", addonService.id);
          
          return new Response(
            JSON.stringify({
              success: true,
              video_url: videoUrl,
              message: "Video already exists",
              already_exists: true,
            }),
            {
              headers: { ...corsHeaders, "Content-Type": "application/json" },
            }
          );
        }
      }
      
      // Refund and error if we couldn't get video URL
      if (!isInternalCall && userId) {
        const { data: currentProfile } = await supabase
          .from("profiles")
          .select("balance")
          .eq("user_id", userId)
          .single();
        
        await supabase
          .from("profiles")
          .update({ balance: (currentProfile?.balance || 0) + price })
          .eq("user_id", userId);
      }
      throw new Error("Video exists but could not retrieve URL");
    }

    if (!response.ok) {
      // Refund if user call
      if (!isInternalCall && userId) {
        const { data: currentProfile } = await supabase
          .from("profiles")
          .select("balance")
          .eq("user_id", userId)
          .single();

        await supabase
          .from("profiles")
          .update({ balance: (currentProfile?.balance || 0) + price })
          .eq("user_id", userId);
        
        await supabase
          .from("track_addons")
          .update({ status: "failed", result_url: JSON.stringify({ error: "Suno API error" }) })
          .eq("track_id", track_id)
          .eq("addon_service_id", addonService.id);
      }
      throw new Error(`Suno API error: ${response.status} - ${responseText}`);
    }

    if (data.code !== 200) {
      // Refund if user call
      if (!isInternalCall && userId) {
        const { data: currentProfile } = await supabase
          .from("profiles")
          .select("balance")
          .eq("user_id", userId)
          .single();
        
        await supabase
          .from("profiles")
          .update({ balance: (currentProfile?.balance || 0) + price })
          .eq("user_id", userId);
        
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

    // Update the track_addons table with processing status and video task ID
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
