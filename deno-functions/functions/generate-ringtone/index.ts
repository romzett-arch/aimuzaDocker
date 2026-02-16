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

  let trackId: string | null = null;

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

    const body = await req.json();
    const { track_id, audio_url, track_title, start_time = 0, duration = 30 } = body;
    trackId = track_id;
    
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    console.log(`Creating ringtone for track: ${track_id}, title: ${track_title}`);

    if (!audio_url) {
      throw new Error("Audio URL is required for ringtone generation");
    }

    // Update the track_addons table with the result (use original audio as ringtone)
    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id")
      .eq("name", "ringtone")
      .single();

    if (addonService) {
      const { error: updateError } = await supabase
        .from("track_addons")
        .update({
          result_url: audio_url,
          status: "completed",
          updated_at: new Date().toISOString(),
        })
        .eq("track_id", track_id)
        .eq("addon_service_id", addonService.id);

      if (updateError) {
        console.error("Update addon error:", updateError);
        throw new Error("Failed to update addon status");
      }
    }

    console.log(`Ringtone created successfully for track: ${track_id}`);

    return new Response(
      JSON.stringify({
        success: true,
        ringtone_url: audio_url,
        message: "Ringtone created successfully",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("generate-ringtone error:", error);
    
    // Update addon status to failed if we have trackId
    if (trackId) {
      try {
        const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
        const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
        const supabase = createClient(supabaseUrl, supabaseServiceKey);
        
        const { data: addonService } = await supabase
          .from("addon_services")
          .select("id")
          .eq("name", "ringtone")
          .single();
          
        if (addonService) {
          await supabase
            .from("track_addons")
            .update({
              status: "failed",
              updated_at: new Date().toISOString(),
            })
            .eq("track_id", trackId)
            .eq("addon_service_id", addonService.id);
        }
      } catch (e) {
        console.error("Failed to update addon status:", e);
      }
    }
    
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
