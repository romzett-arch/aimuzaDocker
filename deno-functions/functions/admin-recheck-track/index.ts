import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  recoverGeneratedTrack,
  type RecoveryTrack,
} from "./recovery.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await supabaseClient.auth.getClaims(token);
    
    if (claimsError || !claimsData?.claims?.sub) {
      console.error("Auth error:", claimsError);
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const userId = claimsData.claims.sub;

    // Check if user is admin (roles are in user_roles table, not profiles)
    const { data: roles } = await supabaseAdmin
      .from("user_roles")
      .select("role")
      .eq("user_id", userId);

    const isAdmin = roles?.some(r => r.role === "admin" || r.role === "super_admin");
    if (!isAdmin) {
      return new Response(
        JSON.stringify({ error: "Forbidden: admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { trackId } = await req.json();

    if (!trackId) {
      return new Response(
        JSON.stringify({ error: "Missing trackId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get track data
    const { data: track, error: trackError } = await supabaseAdmin
      .from("tracks")
      .select("id, user_id, title, description, audio_url, cover_url, duration, status, error_message")
      .eq("id", trackId)
      .single();

    if (trackError || !track) {
      return new Response(
        JSON.stringify({ error: "Track not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[Admin Recheck] Track ${trackId}, status: ${track.status}`);

    const result = await recoverGeneratedTrack(supabaseAdmin, track as RecoveryTrack);
    const { data: updatedTrack } = await supabaseAdmin
      .from("tracks")
      .select("audio_url, status")
      .eq("id", trackId)
      .maybeSingle();

    return new Response(
      JSON.stringify({
        success: result.ok,
        status: updatedTrack?.status || result.sunoStatus || track.status || "unknown",
        message: result.message,
        action: result.action,
        audio_url: updatedTrack?.audio_url || null,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[Admin Recheck] Error:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
