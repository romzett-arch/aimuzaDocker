import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  try {
    // Only allow service-role calls (cron / internal)
    const authHeader = req.headers.get("Authorization");
    if (authHeader !== `Bearer ${supabaseServiceKey}`) {
      return new Response(
        JSON.stringify({ error: "Unauthorized — service key required" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Find expired WAV tracks
    const { data: expiredTracks, error: queryErr } = await supabase
      .from("tracks")
      .select("id, wav_url, wav_expires_at")
      .not("wav_url", "is", null)
      .lt("wav_expires_at", new Date().toISOString())
      .limit(100);

    if (queryErr) {
      throw new Error(`Query failed: ${queryErr.message}`);
    }

    if (!expiredTracks || expiredTracks.length === 0) {
      console.log("[cleanup-wav] No expired WAV files found");
      return new Response(
        JSON.stringify({ success: true, cleaned: 0 }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[cleanup-wav] Found ${expiredTracks.length} expired WAV files`);

    let cleaned = 0;
    let errors = 0;

    for (const track of expiredTracks) {
      try {
        // Delete file from Supabase Storage
        const storagePath = `wav/${track.id}.wav`;
        const { error: deleteErr } = await supabase.storage
          .from("tracks")
          .remove([storagePath]);

        if (deleteErr) {
          console.error(`[cleanup-wav] Storage delete error for ${track.id}:`, deleteErr);
        } else {
          console.log(`[cleanup-wav] Deleted from storage: ${storagePath}`);
        }

        // Clear wav_url and wav_expires_at in tracks table
        await supabase
          .from("tracks")
          .update({
            wav_url: null,
            wav_expires_at: null,
            updated_at: new Date().toISOString(),
          })
          .eq("id", track.id);

        // Mark track_addons as expired
        const { data: addonService } = await supabase
          .from("addon_services")
          .select("id")
          .eq("name", "convert_wav")
          .single();

        if (addonService) {
          await supabase
            .from("track_addons")
            .update({
              status: "expired",
              updated_at: new Date().toISOString(),
            })
            .eq("track_id", track.id)
            .eq("addon_service_id", addonService.id)
            .eq("status", "completed");
        }

        cleaned++;
        console.log(`[cleanup-wav] Cleaned track ${track.id}`);
      } catch (err) {
        errors++;
        console.error(`[cleanup-wav] Error cleaning track ${track.id}:`, err);
      }
    }

    console.log(`[cleanup-wav] Done: ${cleaned} cleaned, ${errors} errors`);

    return new Response(
      JSON.stringify({ success: true, cleaned, errors, total: expiredTracks.length }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("[cleanup-wav] Error:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
