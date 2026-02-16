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
    // Security: Verify request comes from service role (internal calls only)
    const authHeader = req.headers.get("Authorization");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    
    if (authHeader !== `Bearer ${supabaseServiceKey}`) {
      return new Response(
        JSON.stringify({ error: "Unauthorized - internal use only" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { track_id, task_id, audio_id } = await req.json();
    
    console.log("Get timestamped lyrics request:", { track_id, task_id, audio_id });

    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      supabaseServiceKey
    );

    // Call Suno API to get timestamped lyrics
    const response = await fetch("https://api.sunoapi.org/api/v1/generate/get-timestamped-lyrics", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify({
        taskId: task_id,
        audioId: audio_id,
      }),
    });

    const result = await response.json();
    console.log("Suno Timestamped Lyrics API response:", result);

    if (result.code !== 200) {
      throw new Error(result.msg || "Failed to get timestamped lyrics");
    }

    // Store the result
    const { data: service } = await supabase
      .from("addon_services")
      .select("id")
      .eq("name", "timestamped_lyrics")
      .maybeSingle();

    if (service && track_id) {
      await supabase.from("track_addons").insert({
        track_id,
        addon_service_id: service.id,
        status: "completed",
        result_url: JSON.stringify(result.data),
      });
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        data: result.data,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in get-timestamped-lyrics:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
