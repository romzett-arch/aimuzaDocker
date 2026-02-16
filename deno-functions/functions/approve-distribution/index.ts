import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ApproveDistributionInput {
  trackId: string;
  notes?: string;
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

    // Check if user is admin/moderator
    const { data: role } = await supabase
      .from('user_roles')
      .select('role')
      .eq('user_id', userId)
      .in('role', ['admin', 'super_admin', 'moderator'])
      .single();

    if (!role) {
      throw new Error('Not authorized to approve distributions');
    }

    const { trackId, notes }: ApproveDistributionInput = await req.json();
    console.log(`[approve-distribution] Admin ${userId} approving track: ${trackId}`);

    if (!trackId) {
      throw new Error('trackId is required');
    }

    // Get track
    const { data: track, error: trackError } = await supabase
      .from('tracks')
      .select('*')
      .eq('id', trackId)
      .single();

    if (trackError || !track) {
      throw new Error('Track not found');
    }

    if (track.distribution_status !== 'pending_moderation') {
      throw new Error(`Invalid distribution status: ${track.distribution_status}`);
    }

    // Update track - approve for distribution, waiting for master upload
    const { error: updateError } = await supabase
      .from('tracks')
      .update({
        distribution_status: 'pending_master',
        distribution_approved_at: new Date().toISOString(),
        distribution_approved_by: userId,
        moderation_status: 'approved',
        moderation_reviewed_at: new Date().toISOString(),
        moderation_reviewed_by: userId,
        moderation_notes: notes || null
      })
      .eq('id', trackId);

    if (updateError) {
      throw updateError;
    }

    // Log the approval
    await supabase.from('distribution_logs').insert({
      track_id: trackId,
      user_id: userId,
      action: 'distribution_approved',
      stage: 'level_user',
      details: { 
        notes,
        approved_by: userId
      }
    });

    // Notify track owner
    await supabase.from('notifications').insert({
      user_id: track.user_id,
      type: 'system',
      title: '✅ Трек одобрен для дистрибуции!',
      message: `Поздравляем! Трек "${track.title}" прошёл модерацию. Загрузите Master-копию в формате WAV 24-bit для перехода на Level Pro.`,
      actor_id: userId,
      target_type: 'track',
      target_id: trackId
    });

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: 'Distribution approved, awaiting master upload',
        status: 'pending_master'
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[approve-distribution] Error:', error);
    const message = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
