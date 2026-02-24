import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { copyFileToStorage } from "./audio-storage.ts";
import { classifyTrackWithAI, processTrackAddons } from "./classification.ts";
import { getSunoErrorMessage, handleFailedTracksWithRefunds } from "./errors.ts";
import { corsHeaders } from "./types.ts";
import type { MatchedTrack, SunoCallbackPayload, SunoTrackData, TrackToFail } from "./types.ts";

declare const EdgeRuntime: { waitUntil: (promise: Promise<unknown>) => void };

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    if (callbackSecret) {
      const url = new URL(req.url);
      const headerToken = req.headers.get("x-callback-secret") || req.headers.get("authorization")?.replace("Bearer ", "");
      const queryToken = url.searchParams.get("secret");

      if (headerToken !== callbackSecret && queryToken !== callbackSecret) {
        console.error("Invalid callback secret provided");
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      console.log("Callback secret verified successfully");
    } else {
      console.warn("SUNO_CALLBACK_SECRET not configured - callback verification skipped");
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const callbackData = (await req.json()) as SunoCallbackPayload;
    console.log("Received Suno callback:", JSON.stringify(callbackData));

    const tracks = (callbackData?.data?.data || callbackData?.data || []) as SunoTrackData[];
    const taskId = callbackData?.data?.task_id;
    const callbackType = callbackData?.data?.callbackType;
    const responseCode = callbackData?.code;
    const errorMessage = callbackData?.msg;

    console.log(`Callback type: ${callbackType}, Task ID: ${taskId}, Code: ${responseCode}, Tracks count: ${tracks.length}`);

    const isError =
      responseCode !== 200 ||
      callbackType === "fail" ||
      callbackType === "error" ||
      callbackType === "failed";

    if (isError) {
      console.log(`Received error callback for task ${taskId} - code: ${responseCode}, type: ${callbackType}`);

      const errorInfo = getSunoErrorMessage(responseCode || 500, errorMessage || callbackData?.data?.fail_reason);
      const failReason = errorInfo.short;

      let tracksToFail: TrackToFail[] = [];

      if (taskId) {
        const { data: taskTracks } = await supabaseAdmin
          .from("tracks")
          .select("id, user_id, description")
          .in("status", ["processing", "pending"])
          .ilike("description", `%${taskId}%`)
          .limit(2);

        if (taskTracks && taskTracks.length > 0) {
          tracksToFail = taskTracks;
          console.log(`Found ${taskTracks.length} tracks matching task_id ${taskId}`);
        }
      }

      if (tracksToFail.length === 0) {
        const { data: pendingTracks } = await supabaseAdmin
          .from("tracks")
          .select("id, user_id")
          .in("status", ["processing", "pending"])
          .order("created_at", { ascending: false })
          .limit(5);

        if (pendingTracks && pendingTracks.length > 0) {
          tracksToFail = pendingTracks;
        }
      }

      if (tracksToFail.length > 0) {
        await handleFailedTracksWithRefunds(supabaseAdmin, tracksToFail, failReason, errorInfo);
        console.log(`Marked ${tracksToFail.length} tracks as failed with refunds`);
      }

      return new Response(
        JSON.stringify({ received: true, message: "Failure callback processed with refunds" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!Array.isArray(tracks) || tracks.length === 0) {
      console.log("No tracks in callback data");
      return new Response(JSON.stringify({ received: true, message: "No tracks to process" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (callbackType !== "complete") {
      console.log(`Skipping callback type: ${callbackType}`);
      return new Response(JSON.stringify({ received: true, message: `Callback type ${callbackType} acknowledged` }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let allMatchedTracks: MatchedTrack[] = [];

    if (taskId) {
      const { data: taskTracks, error: taskFindError } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description, lyrics, user_id, status")
        .ilike("description", `%[task_id: ${taskId}]%`)
        .order("created_at", { ascending: true })
        .limit(4);

      if (taskFindError) {
        console.error("Error finding tracks by task_id:", taskFindError);
      } else if (taskTracks && taskTracks.length > 0) {
        allMatchedTracks = taskTracks as MatchedTrack[];
        console.log(`Found ${taskTracks.length} tracks matching task_id ${taskId} (statuses: ${taskTracks.map((t) => t.status).join(", ")})`);
      }
    }

    if (allMatchedTracks.length === 0) {
      console.warn(`No tracks found matching task_id ${taskId}. Callback will be ignored to prevent cross-user mixing.`);
      console.warn(`Callback data had ${tracks.length} audio tracks, but no matching DB records.`);
      return new Response(
        JSON.stringify({
          received: true,
          warning: "No matching tracks found for task_id",
          task_id: taskId,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let updatedCount = 0;

    const sortedTracks = [...allMatchedTracks].sort((a, b) => (a.title || "").localeCompare(b.title || ""));

    for (let i = 0; i < tracks.length; i++) {
      const track = tracks[i];
      const {
        id: sunoAudioId,
        audio_url,
        source_audio_url,
        stream_audio_url,
        image_url,
        source_image_url,
        duration,
        title: sunoTitle,
      } = track;

      const rawAudioUrl = audio_url || source_audio_url || stream_audio_url;
      const audioUrl = typeof rawAudioUrl === "string" && rawAudioUrl.startsWith("http") ? rawAudioUrl : null;
      const coverUrl = image_url || source_image_url;

      if (!audioUrl) {
        console.log(`Track has no valid audio URL (raw: ${rawAudioUrl}), skipping`);
        continue;
      }

      if (i >= sortedTracks.length) {
        console.log(`No matched track at index ${i} for Suno result: ${sunoTitle}`);
        continue;
      }

      const trackToUpdate = sortedTracks[i];

      if (trackToUpdate.status === "completed" || trackToUpdate.status === "failed") {
        console.log(`Track ${trackToUpdate.id} (${trackToUpdate.title}) already ${trackToUpdate.status}, skipping — index ${i} preserved for correct mapping`);
        continue;
      }

      console.log(`Updating track ${trackToUpdate.id} (${trackToUpdate.title}) with Suno result[${i}]: ${audioUrl}`);

      let finalAudioUrl = audioUrl;
      let finalCoverUrl = coverUrl;

      try {
        const audioFileName = `${trackToUpdate.id}.mp3`;
        const storedAudioUrl = await copyFileToStorage(supabaseAdmin, audioUrl, "tracks", `audio/${audioFileName}`);
        if (storedAudioUrl) {
          finalAudioUrl = storedAudioUrl;
          console.log(`Audio copied to storage: ${finalAudioUrl}`);
        } else {
          console.log(`Failed to copy audio, using original URL`);
        }
      } catch (audioErr) {
        console.error(`Error copying audio:`, audioErr);
      }

      if (coverUrl) {
        try {
          const coverFileName = `${trackToUpdate.id}.jpg`;
          const storedCoverUrl = await copyFileToStorage(supabaseAdmin, coverUrl, "tracks", `covers/${coverFileName}`);
          if (storedCoverUrl) {
            finalCoverUrl = storedCoverUrl;
            console.log(`Cover copied to storage: ${finalCoverUrl}`);
          } else {
            console.log(`Failed to copy cover, using original URL`);
          }
        } catch (coverErr) {
          console.error(`Error copying cover:`, coverErr);
        }
      }

      const { error: updateError } = await supabaseAdmin
        .from("tracks")
        .update({
          audio_url: finalAudioUrl,
          cover_url: finalCoverUrl || null,
          duration: duration ? Math.round(duration) : null,
          status: "completed",
          suno_audio_id: sunoAudioId || null,
          description: trackToUpdate.description ? `${trackToUpdate.description}\n\n[task_id: ${taskId}]` : `[task_id: ${taskId}]`,
        })
        .eq("id", trackToUpdate.id);

      if (updateError) {
        console.error("Error updating track:", updateError);
      } else {
        console.log(`Track ${trackToUpdate.id} updated successfully with Storage URLs`);
        updatedCount++;

        await supabaseAdmin.from("generation_logs").update({ status: "completed" }).eq("track_id", trackToUpdate.id);

        await processTrackAddons(supabaseAdmin, trackToUpdate.id, trackToUpdate.title || "Untitled", finalCoverUrl, finalAudioUrl, taskId, sunoAudioId);

        const originalDescription = trackToUpdate.description?.replace(/\n\n\[task_id:.*\]$/, "") || null;
        const trackLyrics = trackToUpdate.lyrics || null;

        EdgeRuntime.waitUntil(classifyTrackWithAI(supabaseAdmin, trackToUpdate.id, originalDescription, trackLyrics));
      }
    }

    return new Response(JSON.stringify({ success: true, updated: updatedCount }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Error in suno-callback:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(JSON.stringify({ error: errorMessage }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
