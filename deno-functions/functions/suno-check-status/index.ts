import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  AUDIO_RECOVERY_REQUIRED_MESSAGE,
  copyFirstAvailableFileToStorage,
  isManagedTrackStorageUrl,
} from "../suno-callback/audio-storage.ts";
import { getDurationFromFfmpeg } from "../suno-callback/ffmpeg-duration.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://api.sunoapi.org";

type MatchedTrack = {
  id: string;
  title: string | null;
  description: string | null;
  status: string;
  audio_url: string | null;
  suno_audio_id: string | null;
  error_message: string | null;
};

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

function isRecoveryRequiredError(message: string | null | undefined): boolean {
  return typeof message === "string" && message.includes("не удалось сохранить");
}

// Fetch with retry logic for connection issues
async function fetchWithRetry(url: string, options: RequestInit, maxRetries = 2): Promise<Response> {
  let lastError: Error | null = null;
  
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 10000); // 10s timeout
      
      const response = await fetch(url, {
        ...options,
        signal: controller.signal,
      });
      
      clearTimeout(timeoutId);
      return response;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      console.log(`Fetch attempt ${attempt + 1} failed:`, lastError.message);
      
      // Don't retry on abort
      if (lastError.name === 'AbortError') {
        throw new Error("Request timeout");
      }
      
      // Wait before retry (exponential backoff)
      if (attempt < maxRetries) {
        await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
      }
    }
  }
  
  throw lastError || new Error("Failed after retries");
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
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // Get user via API-compatible auth endpoint
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    
    if (userError || !user) {
      console.error("Auth error:", userError);
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const userId = user.id;

    const { taskId: rawTaskId, trackId } = await req.json();
    
    // Trim whitespace from taskId to prevent URL encoding issues
    const taskId = rawTaskId?.trim();

    if (!taskId) {
      return new Response(
        JSON.stringify({ error: "Missing taskId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Checking status for task ${taskId}`);

    let statusData;
    try {
      const statusResponse = await fetchWithRetry(
        `${SUNO_API_BASE}/api/v1/generate/record-info?taskId=${encodeURIComponent(taskId)}`,
        {
          method: "GET",
          headers: {
            "Authorization": `Bearer ${SUNO_API_KEY}`,
          },
        }
      );
      statusData = await statusResponse.json();
    } catch (fetchError) {
      // Network error - don't mark track as failed, just return processing status
      console.log(`Network error checking status (will retry via polling):`, fetchError);
      return new Response(
        JSON.stringify({ 
          success: false,
          status: "processing",
          message: "Network issue, waiting for callback"
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log("Status response:", JSON.stringify(statusData));

    if (statusData.code === 200 && statusData.data) {
      const records = statusData.data.response?.sunoData || statusData.data.data || [];
      const taskStatus = statusData.data.status;
      
      console.log(`Task status: ${taskStatus}, Records: ${records.length}`);
      
      // Check for failed status — all terminal failure states from Suno API docs
      const TERMINAL_FAILURES = [
        "GENERATE_AUDIO_FAILED", "CREATE_TASK_FAILED",
        "CALLBACK_EXCEPTION", "SENSITIVE_WORD_ERROR",
        "FAILED", "ERROR",
      ];
      if (TERMINAL_FAILURES.includes(taskStatus)) {
        console.log(`Task ${taskId} failed with status: ${taskStatus}`);
        
        if (trackId) {
          const errorMessage = statusData.data.fail_reason || statusData.data.error_message || 
                               statusData.msg || "Генерация отклонена сервисом";
          
          const { error: updateError } = await supabaseClient
            .from("tracks")
            .update({
              status: "failed",
              error_message: errorMessage,
            })
            .eq("id", trackId)
            .eq("user_id", userId);

          if (updateError) {
            console.error("Error updating failed track:", updateError);
          }
        }
        
        return new Response(
          JSON.stringify({ 
            success: false,
            status: taskStatus,
            error: statusData.data.fail_reason || "Generation failed"
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      // Normalize records: collect ALL URL variants for fallback during download.
      // record-info uses camelCase, callback uses snake_case.
      // Priority: sourceAudioUrl (stable CDN) > audioUrl (temp proxy) > stream URLs
      const normalizedRecords = records.map((r: Record<string, unknown>) => {
        const audioUrls = [
          r.sourceAudioUrl, r.source_audio_url,
          r.audioUrl, r.audio_url,
          r.sourceStreamAudioUrl, r.source_stream_audio_url,
          r.streamAudioUrl, r.stream_audio_url,
        ].filter((u): u is string => typeof u === "string" && u.startsWith("http"));

        const imageUrls = [
          r.sourceImageUrl, r.source_image_url,
          r.imageUrl, r.image_url,
        ].filter((u): u is string => typeof u === "string" && u.startsWith("http"));

        return {
          audioUrl: audioUrls[0] || null,
          audioUrls,
          imageUrl: imageUrls[0] || null,
          imageUrls,
          duration: r.duration,
          id: r.id,
        };
      });

      if (normalizedRecords.length > 0 && normalizedRecords.some((r: { audioUrl: string | null }) => r.audioUrl)) {
        let completedByPolling = false;
        let tracksWithTask: MatchedTrack[] = [];

        if (trackId) {
          const { data: targetTrack, error: targetTrackError } = await supabaseClient
            .from("tracks")
            .select("id, title, description, status, audio_url, suno_audio_id, error_message")
            .eq("id", trackId)
            .eq("user_id", userId)
            .maybeSingle();

          if (targetTrackError) {
            console.error(`Error loading target track ${trackId}:`, targetTrackError);
          } else if (targetTrack) {
            const belongsToTask =
              targetTrack.description?.includes(`[task_id: ${taskId}]`) ||
              targetTrack.description?.includes(`[task_id:${taskId}]`);

            if (!belongsToTask) {
              console.warn(`Track ${trackId} does not belong to task ${taskId}, skipping polling recovery`);
            } else if (targetTrack.status === "completed" && isManagedTrackStorageUrl(targetTrack.audio_url)) {
              return new Response(
                JSON.stringify({
                  success: true,
                  status: "completed",
                  records: normalizedRecords,
                }),
                { headers: { ...corsHeaders, "Content-Type": "application/json" } }
              );
            } else if (
              targetTrack.status === "failed" &&
              !isRecoveryRequiredError(targetTrack.error_message)
            ) {
              console.log(`Track ${trackId} is failed for another reason, skipping auto-recovery`);
            } else {
              tracksWithTask = [targetTrack as MatchedTrack];
            }
          }
        } else {
          // Backward-compatible fallback for callers without trackId.
          const { data: matchedTracks } = await supabaseClient
            .from("tracks")
            .select("id, title, description, status, audio_url, suno_audio_id, error_message")
            .eq("user_id", userId)
            .in("status", ["processing", "pending", "failed"])
            .order("created_at", { ascending: true });

          tracksWithTask = (matchedTracks || []).filter(
            (t: { description?: string }) => t.description?.includes(`[task_id: ${taskId}]`) || t.description?.includes(`[task_id:${taskId}]`)
          ) as MatchedTrack[];
        }

        console.log(`Found ${tracksWithTask.length} tracks matching task_id ${taskId} (statuses: ${tracksWithTask.map((t: { status: string }) => t.status).join(",")})`);

        for (const trk of tracksWithTask) {
          const isV2 = /\(v2\)\s*$/.test(trk.title || "");
          const recordIndex = isV2 ? 1 : 0;

          if (recordIndex >= normalizedRecords.length) {
            console.log(`No Suno record at index ${recordIndex} for track ${trk.id} (${trk.title})`);
            continue;
          }

          const rec = normalizedRecords[recordIndex];
          if (!rec.audioUrl) {
            console.log(`Skipping track ${trk.id} — no valid audio URL at index ${recordIndex}`);
            continue;
          }

          if (
            rec.id &&
            trk.suno_audio_id === String(rec.id) &&
            isManagedTrackStorageUrl(trk.audio_url)
          ) {
            console.log(`Track ${trk.id} already saved for Suno audio ${rec.id}, skipping duplicate polling processing`);
            completedByPolling = true;
            continue;
          }

          const finalAudioUrl = await copyFirstAvailableFileToStorage(
            supabaseAdmin,
            rec.audioUrls,
            "tracks",
            `audio/${trk.id}.mp3`,
          );

          // Download cover with fallback chain
          let finalCoverUrl: string | null = null;
          if (rec.imageUrls.length > 0) {
            finalCoverUrl = await copyFirstAvailableFileToStorage(
              supabaseAdmin,
              rec.imageUrls,
              "tracks",
              `covers/${trk.id}.jpg`,
            );
            if (!finalCoverUrl) finalCoverUrl = rec.imageUrl;
          }

          if (!finalAudioUrl) {
            const { error: recoveryError } = await supabaseClient
              .from("tracks")
              .update({
                audio_url: null,
                cover_url: finalCoverUrl,
                status: "failed",
                error_message: AUDIO_RECOVERY_REQUIRED_MESSAGE,
                suno_audio_id: rec.id ? String(rec.id) : null,
              })
              .eq("id", trk.id)
              .eq("user_id", userId);

            if (recoveryError) {
              console.error(`Error marking track ${trk.id} as recovery-required:`, recoveryError);
            } else {
              await supabaseAdmin.from("generation_logs").update({ status: "failed" }).eq("track_id", trk.id);
            }
            continue;
          }

          const durationSec = await resolveTrackDuration(rec.duration, [finalAudioUrl, ...rec.audioUrls]);

          const { error: updateError } = await supabaseClient
            .from("tracks")
            .update({
              audio_url: finalAudioUrl,
              cover_url: finalCoverUrl,
              ...(durationSec != null ? { duration: durationSec } : {}),
              status: "completed",
              error_message: null,
              suno_audio_id: rec.id ? String(rec.id) : null,
            })
            .eq("id", trk.id)
            .eq("user_id", userId);

          if (updateError) {
            console.error(`Error updating track ${trk.id}:`, updateError);
          } else {
            completedByPolling = true;
            await supabaseAdmin.from("generation_logs").update({ status: "completed" }).eq("track_id", trk.id);
            console.log(`Track ${trk.id} (${trk.title}) completed via polling, record[${recordIndex}], suno_audio_id=${rec.id}`);
          }
        }

        if (completedByPolling) {
          return new Response(
            JSON.stringify({
              success: true,
              status: "completed",
              records: normalizedRecords,
            }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
      }

      return new Response(
        JSON.stringify({ 
          success: true,
          status: taskStatus,
          records: normalizedRecords 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    // Handle API error response - but don't mark as failed for 404 (still processing)
    if (statusData.code !== 200) {
      console.log(`Suno API response: code=${statusData.code}, status=${statusData.status}`);
      
      // 404 often means the task is still being processed - don't mark as failed
      if (statusData.status === 404 || statusData.error === "Not Found") {
        console.log("Task not found in API - still processing, waiting for callback");
        return new Response(
          JSON.stringify({ 
            success: false,
            status: "processing",
            message: "Still processing, waiting for callback"
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      // For other errors, mark as failed only if explicitly an error
      if (trackId && statusData.code && statusData.code >= 400 && statusData.code < 500 && statusData.code !== 404) {
        const { error: updateError } = await supabaseClient
          .from("tracks")
          .update({
            status: "failed",
            error_message: statusData.msg || "API error",
          })
          .eq("id", trackId)
          .eq("user_id", userId);

        if (updateError) {
          console.error("Error updating failed track:", updateError);
        }
      }
      
      return new Response(
        JSON.stringify({ 
          success: false,
          status: "processing",
          error: statusData.msg || "API error"
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ 
        success: false,
        status: "pending",
        data: statusData
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in suno-check-status:", error);
    // Don't return 500 for network issues - just indicate still processing
    return new Response(
      JSON.stringify({ 
        success: false,
        status: "processing",
        message: "Checking status, waiting for callback"
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});