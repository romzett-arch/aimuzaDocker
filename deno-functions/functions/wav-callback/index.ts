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

  try {
    const payload = await req.json();
    console.log("WAV callback received:", JSON.stringify(payload));

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { code, data, msg } = payload;

    // The API returns: { code: 200, data: { audio_wav_url: "...", task_id: "..." }, msg: "All generated successfully." }
    // Check for success by code 200 AND presence of audio_wav_url
    if (code === 200 && data?.audio_wav_url) {
      const wavUrl = data.audio_wav_url;
      const taskId = data.task_id;

      console.log(`WAV conversion success! taskId: ${taskId}, wavUrl: ${wavUrl}`);

      // Find the addon by task_id stored in result_url JSON
      const { data: addons } = await supabase
        .from("track_addons")
        .select("id, track_id, result_url")
        .eq("status", "processing")
        .order("created_at", { ascending: false });

      let matchedAddon = null;

      // Find addon that matches the task_id
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

      // Fallback to most recent if no match found
      if (!matchedAddon && addons && addons.length > 0) {
        matchedAddon = addons[0];
        console.log("No task_id match, using most recent addon");
      }

      if (matchedAddon) {
        console.log(`Updating addon ${matchedAddon.id} with WAV URL`);
        
        await supabase
          .from("track_addons")
          .update({ 
            status: "completed",
            result_url: wavUrl,
            updated_at: new Date().toISOString(),
          })
          .eq("id", matchedAddon.id);

        // Also update the track with wav_url for easy access
        await supabase
          .from("tracks")
          .update({ 
            wav_url: wavUrl,
            updated_at: new Date().toISOString(),
          })
          .eq("id", matchedAddon.track_id);

        // Notify user
        const { data: track } = await supabase
          .from("tracks")
          .select("user_id, title")
          .eq("id", matchedAddon.track_id)
          .maybeSingle();

        if (track) {
          await supabase.from("notifications").insert({
            user_id: track.user_id,
            type: "addon_completed",
            title: "WAV готов к скачиванию",
            message: `Трек "${track.title}" конвертирован в WAV формат. Нажмите для скачивания.`,
            target_type: "track",
            target_id: matchedAddon.track_id,
            metadata: { wav_url: wavUrl },
          });
        }

        console.log("WAV conversion completed and saved:", wavUrl);
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
