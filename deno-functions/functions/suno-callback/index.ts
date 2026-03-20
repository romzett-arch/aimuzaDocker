import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  AUDIO_RECOVERY_REQUIRED_MESSAGE,
  copyFirstAvailableFileToStorage,
  isManagedTrackStorageUrl,
} from "./audio-storage.ts";
import { classifyTrackWithAI, processTrackAddons } from "./classification.ts";
import { getDurationFromFfmpeg } from "./ffmpeg-duration.ts";
import { getSunoErrorMessage, handleFailedTracksWithRefunds } from "./errors.ts";
import { corsHeaders } from "./types.ts";
import type { MatchedTrack, SunoCallbackPayload, SunoTrackData, TrackToFail } from "./types.ts";

function getCallbackTaskId(payload: SunoCallbackPayload): string | null {
  return payload?.data?.task_id ?? payload?.data?.taskId ?? null;
}

function runBackgroundTask(task: Promise<unknown>) {
  const runtime = (globalThis as typeof globalThis & {
    EdgeRuntime?: { waitUntil?: (promise: Promise<unknown>) => void };
  }).EdgeRuntime;

  if (runtime?.waitUntil) {
    runtime.waitUntil(task);
    return;
  }

  void task.catch((error) => {
    console.error("Background task failed:", error);
  });
}

function hasDirectAudioSource(track: SunoTrackData): boolean {
  return [
    track.sourceAudioUrl,
    track.source_audio_url,
    track.audioUrl,
    track.audio_url,
  ].some((url) => typeof url === "string" && url.startsWith("http"));
}

async function resolveTrackDuration(
  directDuration: unknown,
  candidateUrls: Array<string | null | undefined>,
): Promise<number | null> {
  if (directDuration != null) {
    const parsed = Math.round(Number(directDuration));
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }

  for (const url of candidateUrls) {
    if (!url) continue;
    const ffmpegDur = await getDurationFromFfmpeg(url);
    if (ffmpegDur != null && ffmpegDur > 0) {
      return ffmpegDur;
    }
  }

  return null;
}

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
    const taskId = getCallbackTaskId(callbackData);
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

      if (!taskId) {
        console.warn("Failure callback received without taskId. Ignoring to prevent cross-user refunds.");
        return new Response(
          JSON.stringify({ received: true, warning: "Failure callback ignored: missing taskId" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { data: taskTracks } = await supabaseAdmin
        .from("tracks")
        .select("id, user_id, description")
        .in("status", ["processing", "pending"])
        .ilike("description", `%[task_id: ${taskId}]%`)
        .limit(2);

      if (!taskTracks || taskTracks.length === 0) {
        console.warn(`Failure callback ignored: no tracks found for task_id ${taskId}`);
        return new Response(
          JSON.stringify({ received: true, warning: "Failure callback ignored: no matching tracks", task_id: taskId }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const tracksToFail: TrackToFail[] = taskTracks;
      await handleFailedTracksWithRefunds(supabaseAdmin, tracksToFail, failReason, errorInfo);
      console.log(`Marked ${tracksToFail.length} tracks as failed with refunds`);

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

    // "text" часто приходит раньше прямых CDN/temp URL и содержит только stream-ссылки.
    // Если начать копирование на этом этапе, параллельный polling/callback начинает дублировать upload-ы.
    if (callbackType === "text" && !tracks.some(hasDirectAudioSource)) {
      console.log(`Skipping text callback for task ${taskId} until direct audio URLs are available`);
      return new Response(JSON.stringify({ received: true, message: "Waiting for direct audio URLs" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // "text" = промежуточный/финальный callback от erweima.ai с готовыми треками
    if (callbackType !== "complete" && callbackType !== "first" && callbackType !== "text") {
      console.log(`Skipping callback type: ${callbackType}`);
      return new Response(JSON.stringify({ received: true, message: `Callback type ${callbackType} acknowledged` }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let allMatchedTracks: MatchedTrack[] = [];

    if (taskId) {
      const { data: taskTracks, error: taskFindError } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description, lyrics, user_id, status, audio_url, suno_audio_id")
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

    // Normalize ALL Suno results — keep original indices intact, collect all URL variants
    const normalizedSunoResults = tracks.map((track: SunoTrackData, idx: number) => {
      const audioUrls = [
        track.sourceAudioUrl, track.source_audio_url,
        track.audioUrl, track.audio_url,
        track.sourceStreamAudioUrl, track.source_stream_audio_url,
        track.streamAudioUrl, track.stream_audio_url,
      ].filter((u): u is string => typeof u === "string" && u.startsWith("http"));
      const coverUrls = [
        track.sourceImageUrl, track.source_image_url,
        track.imageUrl, track.image_url,
      ].filter((u): u is string => typeof u === "string" && u.startsWith("http"));
      const audioUrl = audioUrls[0] || null;
      const coverUrl = coverUrls[0] || null;
      return { ...track, audioUrl, audioUrls, coverUrl, coverUrls, originalIndex: idx };
    });

    // Pending DB tracks (not yet completed/failed)
    const pendingDbTracks = allMatchedTracks.filter(
      (t) => t.status !== "completed" && t.status !== "failed"
    );

    console.log(`Matching ${normalizedSunoResults.length} Suno results to ${pendingDbTracks.length} pending DB tracks (total DB: ${allMatchedTracks.length})`);

    // Match each DB track to its Suno record by title version (v1→index 0, v2→index 1).
    // This is the same logic as suno-check-status to prevent mismatches.
    for (const trackToUpdate of pendingDbTracks) {
      const isV2 = /\(v2\)\s*$/.test(trackToUpdate.title || "");
      const recordIndex = isV2 ? 1 : 0;

      if (recordIndex >= normalizedSunoResults.length) {
        console.log(`No Suno record at index ${recordIndex} for track ${trackToUpdate.id} (${trackToUpdate.title})`);
        continue;
      }

      const track = normalizedSunoResults[recordIndex];
      if (!track.audioUrl) {
        console.log(`Suno record[${recordIndex}] has no audio URL for track ${trackToUpdate.id} (${trackToUpdate.title}), skipping`);
        continue;
      }

      if (callbackType !== "complete" && !hasDirectAudioSource(track)) {
        console.log(`Skipping stream-only record[${recordIndex}] for track ${trackToUpdate.id} until direct audio URL is available`);
        continue;
      }

      const {
        id: sunoAudioId,
        audioUrl,
        duration,
      } = track;

      const coverUrl = track.coverUrl;

      if (
        sunoAudioId &&
        trackToUpdate.suno_audio_id === sunoAudioId &&
        isManagedTrackStorageUrl(trackToUpdate.audio_url)
      ) {
        console.log(`Track ${trackToUpdate.id} already saved for Suno audio ${sunoAudioId}, skipping duplicate callback processing`);
        continue;
      }

      console.log(`Updating track ${trackToUpdate.id} (${trackToUpdate.title}) with Suno record[${recordIndex}]: ${audioUrl}`);

      let finalAudioUrl: string | null = null;
      let finalCoverUrl = coverUrl;

      try {
        const audioFileName = `${trackToUpdate.id}.mp3`;
        const storedAudioUrl = await copyFirstAvailableFileToStorage(
          supabaseAdmin,
          track.audioUrls,
          "tracks",
          `audio/${audioFileName}`,
        );
        if (storedAudioUrl) {
          finalAudioUrl = storedAudioUrl;
          console.log(`Audio copied to storage: ${finalAudioUrl}`);
        } else {
          console.error(`Failed to copy audio for track ${trackToUpdate.id}; keeping track in recovery-required state`);
        }
      } catch (audioErr) {
        console.error(`Error copying audio:`, audioErr);
      }

      if (coverUrl) {
        try {
          const coverFileName = `${trackToUpdate.id}.jpg`;
          const storedCoverUrl = await copyFirstAvailableFileToStorage(
            supabaseAdmin,
            track.coverUrls,
            "tracks",
            `covers/${coverFileName}`,
          );
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

      // Preserve description without duplicating task_id
      const descAlreadyHasTaskId = trackToUpdate.description?.includes("[task_id:");
      const updatedDescription = descAlreadyHasTaskId
        ? trackToUpdate.description
        : (trackToUpdate.description ? `${trackToUpdate.description}\n\n[task_id: ${taskId}]` : `[task_id: ${taskId}]`);

      if (!finalAudioUrl) {
        const { error: recoveryError } = await supabaseAdmin
          .from("tracks")
          .update({
            audio_url: null,
            cover_url: finalCoverUrl || null,
            status: "failed",
            error_message: AUDIO_RECOVERY_REQUIRED_MESSAGE,
            suno_audio_id: sunoAudioId || null,
            description: updatedDescription,
          })
          .eq("id", trackToUpdate.id);

        if (recoveryError) {
          console.error("Error marking track as recovery-required:", recoveryError);
        } else {
          await supabaseAdmin.from("generation_logs").update({ status: "failed" }).eq("track_id", trackToUpdate.id);
        }
        continue;
      }

      const durationSec = await resolveTrackDuration(duration, [finalAudioUrl, ...track.audioUrls]);

      const { error: updateError } = await supabaseAdmin
        .from("tracks")
        .update({
          audio_url: finalAudioUrl,
          cover_url: finalCoverUrl || null,
          ...(durationSec != null ? { duration: durationSec } : {}),
          status: "completed",
          suno_audio_id: sunoAudioId || null,
          description: updatedDescription,
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

        runBackgroundTask(
          classifyTrackWithAI(supabaseAdmin, trackToUpdate.id, originalDescription, trackLyrics),
        );
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
