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
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const body = await req.json();
    console.log("Suno video callback received:", JSON.stringify(body));

    const { code, msg, data } = body;

    if (code !== 200) {
      console.error(`Suno video callback error: ${msg}`);
      return new Response(JSON.stringify({ received: true, error: msg }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Extract task_id and video_url - Suno may send different formats
    const task_id = data?.task_id;
    const video_url = data?.video_url;
    
    // Determine callback type from response structure
    let callbackType = data?.callbackType;
    if (!callbackType && video_url) {
      callbackType = "complete"; // If we have video_url, it's complete
    }
    console.log(`Video callback type: ${callbackType}, task_id: ${task_id}`);

    // Find the track addon with this video task ID
    // The result_url field contains JSON with video_task_id
    const { data: addons, error: findError } = await supabase
      .from("track_addons")
      .select("*, addon_services!inner(name), tracks!inner(id, user_id, title, suno_audio_id)")
      .eq("addon_services.name", "short_video")
      .eq("status", "processing");

    if (findError) {
      console.error("Error finding addons:", findError);
      return new Response(JSON.stringify({ received: true, error: "Error finding addon" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Find the addon that matches this video task_id
    let matchedAddon = null;
    for (const addon of addons || []) {
      try {
        const resultData = typeof addon.result_url === 'string' 
          ? JSON.parse(addon.result_url) 
          : addon.result_url;
        
        if (resultData?.video_task_id === task_id) {
          matchedAddon = addon;
          break;
        }
      } catch (e) {
        console.log(`Failed to parse result_url for addon ${addon.id}:`, e);
      }
    }

    if (!matchedAddon) {
      console.log("No matching addon found for video task_id:", task_id);
      return new Response(JSON.stringify({ received: true, message: "No matching addon" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const trackData = matchedAddon.tracks as { id: string; user_id: string; title: string; suno_audio_id: string | null };
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

      // Create notification for user
      await supabase.from("notifications").insert({
        user_id: userId,
        type: "addon_failed",
        title: "Ошибка создания видео",
        message: `Не удалось создать видео для трека "${trackTitle}"`,
        target_type: "track",
        target_id: trackId,
      });
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
