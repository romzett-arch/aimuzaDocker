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
  weighted_likes_sum: number;
  weighted_dislikes_sum: number;
  voting_ends_at: string;
  user_id: string;
  distribution_status?: string;
  forum_topic_id?: string | null;
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
      .select("id, title, voting_likes_count, voting_dislikes_count, weighted_likes_sum, weighted_dislikes_sum, voting_ends_at, user_id, distribution_status, forum_topic_id")
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
      const weightedLikes = Number(track.weighted_likes_sum) || 0;
      const weightedDislikes = Number(track.weighted_dislikes_sum) || 0;
      const totalWeight = weightedLikes + weightedDislikes;
      const totalVotes = (track.voting_likes_count || 0) + (track.voting_dislikes_count || 0);
      let votingResult: "voting_approved" | "rejected";
      let newModerationStatus: "pending" | "rejected";
      let reason: string;

      if (totalVotes < minVotes) {
        votingResult = "rejected";
        newModerationStatus = "rejected";
        reason = `Недостаточно голосов: ${totalVotes} из ${minVotes} минимальных`;
      } else {
        const likeRatio = totalWeight > 0 ? weightedLikes / totalWeight : (track.voting_likes_count || 0) / Math.max(1, totalVotes);
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
      // When distribution_status = 'voting', also update distribution flow
      const isDistributionVoting = track.distribution_status === "voting";
      const newDistributionStatus = isDistributionVoting
        ? (newModerationStatus === "pending" ? "pending_master" : "rejected")
        : undefined;

      const updatePayload: Record<string, unknown> = {
        moderation_status: newModerationStatus,
        voting_result: votingResult,
        is_public: false, // Keep hidden - label makes final decision
      };
      if (newDistributionStatus !== undefined) {
        updatePayload.distribution_status = newDistributionStatus;
      }

      const { error: updateError } = await supabase
        .from("tracks")
        .update(updatePayload)
        .eq("id", track.id);

      if (updateError) {
        console.error(`Failed to update track ${track.id}:`, updateError);
        continue;
      }

      // Forum Lock: post closure message and lock topic
      if (track.forum_topic_id) {
        const likeRatio = totalWeight > 0 ? weightedLikes / totalWeight : (track.voting_likes_count || 0) / Math.max(1, totalVotes);
        const closureMsg = `✅ **Голосование завершено. Решение принято.**\n\n` +
          (votingResult === "voting_approved"
            ? `Трек одобрен для дистрибуции (${Math.round(likeRatio * 100)}% положительных голосов).`
            : `Трек не прошёл голосование (${Math.round(likeRatio * 100)}% положительных, требуется ${Math.round(approvalRatio * 100)}%).`);
        await supabase.from("forum_posts").insert({
          topic_id: track.forum_topic_id,
          user_id: "00000000-0000-0000-0000-000000000000",
          content: closureMsg,
        });
        await supabase.from("forum_topics").update({ is_locked: true, is_pinned: false }).eq("id", track.forum_topic_id);
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
