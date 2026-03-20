import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  extractTaskId,
  recoverGeneratedTrack,
  type RecoveryTrack,
} from "../admin-recheck-track/recovery.ts";
import {
  AUDIO_RECOVERY_REQUIRED_MESSAGE,
  isManagedTrackStorageUrl,
} from "../suno-callback/audio-storage.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

function isRecoveryRequiredError(message: string | null | undefined): boolean {
  return typeof message === "string" && message.includes("не удалось сохранить");
}

function isBackfillCandidate(track: RecoveryTrack): boolean {
  if (track.status !== "completed" && !isRecoveryRequiredError(track.error_message)) {
    return false;
  }

  if (!extractTaskId(track.description)) {
    return false;
  }

  if (isRecoveryRequiredError(track.error_message)) {
    return true;
  }

  return !!track.audio_url && !isManagedTrackStorageUrl(track.audio_url);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await supabaseClient.auth.getClaims(token);
    if (claimsError || !claimsData?.claims?.sub) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const userId = claimsData.claims.sub;
    const { data: roles } = await supabaseAdmin
      .from("user_roles")
      .select("role")
      .eq("user_id", userId);

    const isAdmin = roles?.some((role) => role.role === "admin" || role.role === "super_admin");
    if (!isAdmin) {
      return new Response(
        JSON.stringify({ error: "Forbidden: admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const body = await req.json().catch(() => ({}));
    const requestedLimit = Number(body?.limit);
    const limit = Number.isFinite(requestedLimit) ? Math.min(Math.max(Math.round(requestedLimit), 1), 100) : 25;
    const dryRun = Boolean(body?.dryRun);
    const scanLimit = Math.min(Math.max(limit * 10, 100), 1000);

    const { data: tracks, error: tracksError } = await supabaseAdmin
      .from("tracks")
      .select("id, user_id, title, description, audio_url, cover_url, duration, status, error_message, created_at")
      .eq("source_type", "generated")
      .in("status", ["completed", "failed"])
      .order("created_at", { ascending: true })
      .limit(scanLimit);

    if (tracksError) {
      throw tracksError;
    }

    const candidates = (tracks || [])
      .filter((track) => isBackfillCandidate(track as RecoveryTrack))
      .slice(0, limit);

    if (dryRun) {
      return new Response(
        JSON.stringify({
          success: true,
          dryRun: true,
          scanned: tracks?.length || 0,
          candidates: candidates.map((track) => ({
            id: track.id,
            title: track.title,
            status: track.status,
            audio_url: track.audio_url,
            error_message: track.error_message,
            recovery_required: isRecoveryRequiredError(track.error_message),
          })),
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const results = [];
    let recovered = 0;
    let failed = 0;

    for (const track of candidates) {
      const result = await recoverGeneratedTrack(supabaseAdmin, track as RecoveryTrack, {
        persistFailure: false,
      });

      if (result.ok) {
        recovered++;
      } else {
        failed++;
      }

      results.push({
        trackId: track.id,
        title: track.title,
        ok: result.ok,
        action: result.action,
        message: result.message,
      });
    }

    return new Response(
      JSON.stringify({
        success: true,
        dryRun: false,
        scanned: tracks?.length || 0,
        processed: candidates.length,
        recovered,
        failed,
        note: AUDIO_RECOVERY_REQUIRED_MESSAGE,
        results,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("[Admin Backfill Generated Audio] Error:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
