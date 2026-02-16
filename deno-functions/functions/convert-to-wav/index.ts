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

    // Check if this is an internal call with service key
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
    const { track_id, audio_id } = body;
    
    console.log("Convert to WAV request:", { track_id, audio_id, userId, isInternalCall });

    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get track info to get task_id from description
    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, suno_audio_id, title, description, audio_url, wav_url")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    // If WAV already exists on track, return it
    if (track.wav_url) {
      console.log("WAV already exists on track:", track.wav_url);
      return new Response(
        JSON.stringify({ success: true, wav_url: track.wav_url, message: "WAV already available" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // If user call, verify ownership
    if (!isInternalCall && track.user_id !== userId) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Extract task_id from track description
    let taskId: string | null = null;
    if (track.description) {
      const taskIdMatch = track.description.match(/\[task_id:\s*([^\]]+)\]/);
      if (taskIdMatch) {
        taskId = taskIdMatch[1].trim();
      }
    }

    // Use provided audio_id or get from track
    const audioId = audio_id || track.suno_audio_id;

    if (!taskId) {
      throw new Error("Track has no Suno task ID for WAV conversion");
    }

    // Get addon service
    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id, price_rub")
      .eq("name", "convert_wav")
      .single();

    if (!addonService) {
      throw new Error("WAV conversion service not found");
    }

    const callbackUrl = `${supabaseUrl}/functions/v1/wav-callback`;

    // Call Suno API to convert to WAV
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

    // Handle "already exists" case - try to get the WAV URL directly
    if (result.code === 409 && result.data?.taskId) {
      console.log("WAV already exists, fetching record-info...");
      
      // Get WAV record info from Suno API - correct endpoint is /wav/record-info
      const statusResponse = await fetch(`https://api.sunoapi.org/api/v1/wav/record-info?taskId=${result.data.taskId}`, {
        method: "GET",
        headers: {
          "Authorization": `Bearer ${SUNO_API_KEY}`,
        },
      });
      
      const statusResult = await statusResponse.json();
      console.log("WAV record-info response:", statusResult);
      
      // Check if WAV URL is available - the field is "audioWavUrl" in "response" object
      if (statusResult.code === 200 && statusResult.data?.response?.audioWavUrl) {
        const wavUrl = statusResult.data.response.audioWavUrl;
        console.log("Found WAV URL from record-info:", wavUrl);
        
        // Update track with WAV URL
        await supabase
          .from("tracks")
          .update({ 
            wav_url: wavUrl,
            updated_at: new Date().toISOString(),
          })
          .eq("id", track_id);
        
        // Update addon status
        await supabase.from("track_addons").upsert({
          track_id,
          addon_service_id: addonService.id,
          status: "completed",
          result_url: wavUrl,
          updated_at: new Date().toISOString(),
        }, {
          onConflict: "track_id,addon_service_id",
        });
        
        // Send notification
        await supabase.from("notifications").insert({
          user_id: track.user_id,
          type: "addon_completed",
          title: "WAV готов к скачиванию",
          message: `Трек "${track.title}" доступен в WAV формате.`,
          target_type: "track",
          target_id: track_id,
          metadata: { wav_url: wavUrl },
        });
        
        return new Response(
          JSON.stringify({ success: true, wav_url: wavUrl, message: "WAV ready" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      // Status not ready yet, keep waiting
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

    // Create or update addon record
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
