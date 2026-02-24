import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { PlagiarismRequest, CheckStep } from "./types.ts";
import { runAcoustidStep, runAcrcloudStep, runInternalStep } from "./steps.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const ACOUSTID_API_KEY = Deno.env.get('ACOUSTID_API_KEY');
    const FFMPEG_API_URL = Deno.env.get('FFMPEG_API_URL');
    const FFMPEG_API_SECRET = Deno.env.get('FFMPEG_API_SECRET');
    const ACRCLOUD_HOST = Deno.env.get('ACRCLOUD_HOST');
    const ACRCLOUD_ACCESS_KEY = Deno.env.get('ACRCLOUD_ACCESS_KEY');
    const ACRCLOUD_ACCESS_SECRET = Deno.env.get('ACRCLOUD_ACCESS_SECRET');

    const { trackId, audioUrl }: PlagiarismRequest = await req.json();
    console.log(`[check-plagiarism] Starting check for track: ${trackId}`);

    if (!trackId || !audioUrl) {
      throw new Error('trackId and audioUrl are required');
    }

    const { data: trackData } = await supabase
      .from('tracks')
      .select('user_id, title')
      .eq('id', trackId)
      .single();

    const userId = trackData?.user_id;

    const steps: CheckStep[] = [
      { id: 'acoustid', name: 'AcoustID Fingerprint', database: 'MusicBrainz (45M+ треков)', status: 'pending' },
      { id: 'acrcloud', name: 'ACRCloud', database: 'Глобальная база (100M+ треков)', status: 'pending' },
      { id: 'internal', name: 'Внутренняя база', database: 'AI Planet Sound', status: 'pending' },
    ];

    await supabase
      .from('tracks')
      .update({
        copyright_check_status: 'checking',
        plagiarism_check_status: 'checking'
      })
      .eq('id', trackId);

    if (userId) {
      await supabase.from('distribution_logs').insert({
        track_id: trackId,
        user_id: userId,
        action: 'plagiarism_check_started',
        stage: 'upload',
        details: { audio_url: audioUrl, steps: steps.map(s => s.id) }
      });
    }

    const { matches: acoustidMatches, success: acoustidSuccess, error: acoustidError } = await runAcoustidStep(
      steps, audioUrl, ACOUSTID_API_KEY, FFMPEG_API_URL, FFMPEG_API_SECRET
    );

    const { matches: acrcloudMatches, success: acrcloudSuccess, error: acrcloudError } = await runAcrcloudStep(
      steps, audioUrl, ACRCLOUD_HOST, ACRCLOUD_ACCESS_KEY, ACRCLOUD_ACCESS_SECRET
    );

    const { matches: internalMatches } = await runInternalStep(
      steps, supabase, trackId, trackData?.title?.toLowerCase() || '', userId
    );

    const allMatches = [...acoustidMatches, ...acrcloudMatches, ...internalMatches];
    const isClean = allMatches.length === 0;
    const score = isClean ? 100 : Math.max(0, 100 - Math.max(...allMatches.map(m => m.similarity)));

    console.log(`[check-plagiarism] Result for ${trackId}: isClean=${isClean}, score=${score}, matches=${allMatches.length}`);

    const { error: updateError } = await supabase
      .from('tracks')
      .update({
        copyright_check_status: isClean ? 'clean' : 'flagged',
        plagiarism_check_status: isClean ? 'clean' : 'flagged',
        plagiarism_check_result: {
          isClean,
          score,
          matches: allMatches,
          steps: steps.map(s => ({
            id: s.id,
            name: s.name,
            database: s.database,
            status: s.status,
            matchCount: s.result?.matches?.length || 0
          })),
          checkedAt: new Date().toISOString(),
          acoustidAvailable: acoustidSuccess,
          acoustidError,
          acrcloudAvailable: acrcloudSuccess,
          acrcloudError
        }
      })
      .eq('id', trackId);

    if (updateError) {
      console.error('[check-plagiarism] Update error:', updateError);
      throw updateError;
    }

    if (userId) {
      await supabase.from('distribution_logs').insert({
        track_id: trackId,
        user_id: userId,
        action: isClean ? 'plagiarism_check_clean' : 'plagiarism_check_flagged',
        stage: 'upload',
        details: { isClean, score, matchCount: allMatches.length, steps: steps.map(s => s.id) }
      });
    }

    const processedSteps = steps.map(s => ({
      id: s.id,
      name: s.name,
      database: s.database,
      status: s.status,
      matchCount: s.result?.matches?.length || 0
    }));

    return new Response(
      JSON.stringify({
        success: true,
        isClean,
        score,
        matches: allMatches,
        steps: processedSteps,
        message: isClean ? 'Трек прошёл проверку' : 'Обнаружены совпадения'
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[check-plagiarism] Error:', error);
    const message = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
