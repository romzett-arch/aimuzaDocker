import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface RequestDistributionInput {
  trackId: string;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Get user from auth header using getClaims (more reliable)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('No authorization header');
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: claimsData, error: claimsError } = await supabase.auth.getClaims(token);
    
    if (claimsError || !claimsData?.claims?.sub) {
      throw new Error('Unauthorized');
    }
    
    const userId = claimsData.claims.sub as string;

    const { trackId }: RequestDistributionInput = await req.json();
    console.log(`[request-distribution] User ${userId} requesting distribution for track: ${trackId}`);

    if (!trackId) {
      throw new Error('trackId is required');
    }

    // Get track and verify ownership
    const { data: track, error: trackError } = await supabase
      .from('tracks')
      .select('*')
      .eq('id', trackId)
      .single();

    if (trackError || !track) {
      throw new Error('Track not found');
    }

    if (track.user_id !== userId) {
      throw new Error('Not authorized to request distribution for this track');
    }

    // Check if already in distribution process
    if (track.distribution_status !== 'none') {
      throw new Error(`Track is already in distribution process: ${track.distribution_status}`);
    }

    // Check plagiarism status
    if (track.plagiarism_check_status !== 'clean') {
      throw new Error('Track must pass plagiarism check first');
    }

    // Update track status
    const { error: updateError } = await supabase
      .from('tracks')
      .update({
        distribution_status: 'pending_moderation',
        distribution_requested_at: new Date().toISOString()
      })
      .eq('id', trackId);

    if (updateError) {
      throw updateError;
    }

    // Log the request
    await supabase.from('distribution_logs').insert({
      track_id: trackId,
      user_id: userId,
      action: 'distribution_requested',
      stage: 'level_user',
      details: { 
        track_title: track.title,
        plagiarism_status: track.plagiarism_check_status
      }
    });

    // Notify admins
    const { data: admins } = await supabase
      .from('user_roles')
      .select('user_id')
      .in('role', ['admin', 'super_admin', 'moderator']);

    if (admins) {
      const notifications = admins.map(admin => ({
        user_id: admin.user_id,
        type: 'moderation',
        title: '📤 Запрос на дистрибуцию',
        message: `Пользователь запросил дистрибуцию трека "${track.title}"`,
        actor_id: userId,
        target_type: 'track',
        target_id: trackId
      }));

      await supabase.from('notifications').insert(notifications);
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: 'Distribution request submitted',
        status: 'pending_moderation'
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[request-distribution] Error:', error);
    const message = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
