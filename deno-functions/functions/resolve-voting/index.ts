import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface VotingTrack {
  id: string;
  title: string;
  voting_likes_count: number;
  voting_dislikes_count: number;
  voting_ends_at: string;
  user_id: string;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get tracks with expired voting
    const { data: expiredTracks, error: fetchError } = await supabase
      .from("tracks")
      .select("id, title, voting_likes_count, voting_dislikes_count, voting_ends_at, user_id")
      .eq("moderation_status", "voting")
      .lt("voting_ends_at", new Date().toISOString());

    if (fetchError) {
      throw fetchError;
    }

    if (!expiredTracks?.length) {
      return new Response(
        JSON.stringify({ message: "No expired voting tracks found", processed: 0 }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`Processing ${expiredTracks.length} expired voting tracks`);

    // Get voting settings
    const { data: settings } = await supabase
      .from("settings")
      .select("key, value")
      .in("key", ["voting_min_votes", "voting_approval_ratio", "voting_notify_artist"]);

    const settingsMap = new Map(settings?.map(s => [s.key, s.value]) || []);
    const minVotes = parseInt(settingsMap.get("voting_min_votes") || "10", 10);
    const approvalRatio = parseFloat(settingsMap.get("voting_approval_ratio") || "0.6");
    const notifyArtist = settingsMap.get("voting_notify_artist") !== "false"; // default true

    const results: Array<{ trackId: string; title: string; result: string; reason: string }> = [];

    for (const track of expiredTracks as VotingTrack[]) {
      const totalVotes = (track.voting_likes_count || 0) + (track.voting_dislikes_count || 0);
      let votingResult: "voting_approved" | "rejected";
      let newModerationStatus: "pending" | "rejected";
      let reason: string;

      if (totalVotes < minVotes) {
        votingResult = "rejected";
        newModerationStatus = "rejected";
        reason = `Недостаточно голосов: ${totalVotes} из ${minVotes} минимальных`;
      } else {
        const likeRatio = (track.voting_likes_count || 0) / totalVotes;
        if (likeRatio >= approvalRatio) {
          votingResult = "voting_approved";
          newModerationStatus = "pending"; // Back to moderation queue for final label decision
          reason = `Голосование пройдено: ${Math.round(likeRatio * 100)}% положительных голосов. Возвращён на модерацию для финального решения.`;
        } else {
          votingResult = "rejected";
          newModerationStatus = "rejected";
          reason = `Отклонено: ${Math.round(likeRatio * 100)}% положительных (нужно ${Math.round(approvalRatio * 100)}%)`;
        }
      }

      // Update track status
      // CRITICAL: Do NOT auto-publish! Track goes back to moderation queue
      const { error: updateError } = await supabase
        .from("tracks")
        .update({
          moderation_status: newModerationStatus,
          voting_result: votingResult,
          is_public: false, // Keep hidden - label makes final decision
        })
        .eq("id", track.id);

      if (updateError) {
        console.error(`Failed to update track ${track.id}:`, updateError);
        continue;
      }

      // Notify artist
      if (notifyArtist && track.user_id) {
        await supabase
          .from("notifications")
          .insert({
            user_id: track.user_id,
            type: "voting_result",
            title: votingResult === "voting_approved" 
              ? "🎉 Голосование пройдено!" 
              : "Голосование завершено",
            message: votingResult === "voting_approved"
              ? `Трек "${track.title}" успешно прошёл голосование и отправлен на финальное рассмотрение лейбла.`
              : `К сожалению, трек "${track.title}" не набрал достаточно голосов. ${reason}`,
            target_type: "track",
            target_id: track.id,
          });
      }

      results.push({
        trackId: track.id,
        title: track.title,
        result: votingResult,
        reason,
      });

      console.log(`Track "${track.title}" (${track.id}): ${votingResult} -> moderation_status=${newModerationStatus}`);
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        processed: results.length,
        results,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Error in resolve-voting:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
