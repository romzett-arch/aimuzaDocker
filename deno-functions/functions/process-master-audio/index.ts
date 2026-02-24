import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, PROCESSING_STAGES } from "./types.ts";
import type { ProcessMasterRequest } from "./types.ts";
import { runMasterProcessing } from "./processor.ts";

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
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

    console.log(`[process-master-audio] Track: "${track.title}", user: ${track.user_id}`);

    const result = await runMasterProcessing(supabase, trackId, masterAudioUrl, track, corsHeaders);

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
