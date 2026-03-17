import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, PROCESSING_STAGES } from "./types.ts";
import type { ProcessMasterRequest } from "./types.ts";
import { runMasterProcessing } from "./processor.ts";

function normalizeTrackUrl(rawUrl: string | null | undefined, requestUrl: string): string | null {
  if (!rawUrl) return null;

  try {
    const baseUrl = Deno.env.get("BASE_URL") || new URL(requestUrl).origin;
    const normalized = new URL(rawUrl, baseUrl);
    if (!["http:", "https:"].includes(normalized.protocol)) {
      return null;
    }
    normalized.hash = "";
    return normalized.toString();
  } catch {
    return null;
  }
}

function resolveTrustedTrackUrl(
  candidateUrl: string,
  allowedUrls: Array<string | null | undefined>,
  requestUrl: string,
): string | null {
  const normalizedCandidate = normalizeTrackUrl(candidateUrl, requestUrl);
  if (!normalizedCandidate) return null;

  const trustedUrls = new Set(
    allowedUrls
      .map((value) => normalizeTrackUrl(value, requestUrl))
      .filter((value): value is string => Boolean(value)),
  );

  return trustedUrls.has(normalizedCandidate) ? normalizedCandidate : null;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } }
    });
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();

    if (userError || !user) {
      return new Response(
        JSON.stringify({ success: false, error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(
      supabaseUrl,
      serviceRoleKey
    );

    const { trackId, masterAudioUrl }: ProcessMasterRequest = await req.json();
    console.log(`[process-master-audio] ▶ Starting REAL processing for track: ${trackId}`);

    if (!trackId || !masterAudioUrl) {
      throw new Error('trackId and masterAudioUrl are required');
    }

    const { data: track, error: trackError } = await supabase
      .from('tracks')
      .select('*')
      .eq('id', trackId)
      .maybeSingle();

    if (trackError) {
      console.error('[process-master-audio] DB error:', trackError);
      throw new Error(`Database error: ${trackError.message}`);
    }
    if (!track) {
      throw new Error(`Track not found: ${trackId}`);
    }

    if (track.user_id !== user.id) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden" }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const trustedMasterAudioUrl = resolveTrustedTrackUrl(
      masterAudioUrl,
      [track.master_audio_url, track.audio_url, track.normalized_audio_url],
      req.url
    );

    if (!trustedMasterAudioUrl) {
      return new Response(
        JSON.stringify({ success: false, error: "masterAudioUrl must match the track file URL" }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[process-master-audio] Track: "${track.title}", user: ${track.user_id}`);

    const result = await runMasterProcessing(supabase, trackId, trustedMasterAudioUrl, track, corsHeaders);

    if (result instanceof Response) {
      return result;
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Gold pack assembled with real audio processing',
        stages_completed: PROCESSING_STAGES.length,
        real_processing: true,
        details: result.completionDetails,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[process-master-audio] FATAL:', error);
    const message = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
