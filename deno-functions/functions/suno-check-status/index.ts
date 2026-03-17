import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getDurationFromFfmpeg } from "../suno-callback/ffmpeg-duration.ts";
import {
  markGenerationLogsCompleted,
  markTracksFailed,
  normalizeSunoRecords,
  refundPendingGenerationLogs,
  SUNO_API_BASE,
  SUNO_TERMINAL_FAILURES,
} from "../../shared/suno.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "http://api:3000";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const BASE_URL = Deno.env.get("BASE_URL") || "http://localhost";

async function downloadToLocalStorage(
  externalUrl: string,
  bucket: string,
  filePath: string,
  maxRetries = 2,
): Promise<string | null> {
  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    try {
      const response = await fetch(externalUrl);
      if (!response.ok) {
        if (attempt < maxRetries) {
          await new Promise((resolve) => setTimeout(resolve, 1500 * (attempt + 1)));
        }
        continue;
      }

      const blob = await response.blob();
      const buffer = new Uint8Array(await blob.arrayBuffer());
      if (buffer.length < 1000) {
        if (attempt < maxRetries) {
          await new Promise((resolve) => setTimeout(resolve, 1500 * (attempt + 1)));
        }
        continue;
      }

      const uploadResponse = await fetch(`${SUPABASE_URL}/storage/v1/object/${bucket}/${filePath}`, {
        method: "PUT",
        headers: {
          "Content-Type": blob.type || "application/octet-stream",
          "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
        },
        body: buffer,
      });

      if (!uploadResponse.ok) {
        if (attempt < maxRetries) {
          await new Promise((resolve) => setTimeout(resolve, 1500 * (attempt + 1)));
        }
        continue;
      }

      return `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`;
    } catch (error) {
      console.error("[suno-check-status] downloadToLocalStorage failed:", error);
      if (attempt < maxRetries) {
        await new Promise((resolve) => setTimeout(resolve, 1500 * (attempt + 1)));
      }
    }
  }

  return null;
}

async function fetchWithRetry(url: string, options: RequestInit, maxRetries = 2): Promise<Response> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 10000);
      const response = await fetch(url, { ...options, signal: controller.signal });
      clearTimeout(timeoutId);
      return response;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (lastError.name === "AbortError") {
        throw new Error("Request timeout");
      }
      if (attempt < maxRetries) {
        await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)));
      }
    }
  }

  throw lastError || new Error("Failed after retries");
}

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { taskId: rawTaskId } = await req.json();
    const taskId = rawTaskId?.trim();
    if (!taskId) {
      return new Response(
        JSON.stringify({ error: "Missing taskId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (!SUNO_API_KEY) {
      return new Response(
        JSON.stringify({ success: false, status: "processing", message: "Suno API key is missing" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    let statusData;
    try {
      const statusResponse = await fetchWithRetry(
        `${SUNO_API_BASE}/api/v1/generate/record-info?taskId=${encodeURIComponent(taskId)}`,
        {
          method: "GET",
          headers: { "Authorization": `Bearer ${SUNO_API_KEY}` },
        },
      );
      statusData = await statusResponse.json();
    } catch (error) {
      console.log("[suno-check-status] Network error:", error);
      return new Response(
        JSON.stringify({ success: false, status: "processing", message: "Network issue, waiting for callback" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (statusData.code === 200 && statusData.data) {
      const taskStatus = statusData.data.status;
      const rawRecords = statusData.data.response?.sunoData || statusData.data.data || [];
      const normalizedRecords = normalizeSunoRecords(rawRecords as Array<Record<string, unknown>>);

      const { data: matchedTracks } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description, status")
        .eq("user_id", user.id)
        .in("status", ["processing", "pending", "failed"])
        .order("created_at", { ascending: true });

      const tracksWithTask = (matchedTracks || []).filter(
        (track: { description?: string }) =>
          track.description?.includes(`[task_id: ${taskId}]`) ||
          track.description?.includes(`[task_id:${taskId}]`),
      );
      const taskTrackIds = tracksWithTask.map((track: { id: string }) => track.id);

      if (SUNO_TERMINAL_FAILURES.has(taskStatus)) {
        const errorMessage =
          statusData.data.fail_reason || statusData.data.error_message || statusData.msg || "Генерация отклонена сервисом";

        await markTracksFailed(supabaseAdmin, taskTrackIds, errorMessage, user.id);
        const refundResult = await refundPendingGenerationLogs(supabaseAdmin, {
          userId: user.id,
          trackIds: taskTrackIds,
          reason: `Возврат за ошибку генерации: ${errorMessage}`,
          fullMessage: errorMessage,
        });

        return new Response(
          JSON.stringify({
            success: false,
            status: taskStatus,
            error: errorMessage,
            refunded: refundResult.refundedAmount > 0,
            refundAmount: refundResult.refundedAmount,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (normalizedRecords.length > 0 && normalizedRecords.some((record) => record.audioUrl)) {
        const completedTrackIds: string[] = [];

        for (const track of tracksWithTask) {
          const isV2 = /\(v2\)\s*$/.test(track.title || "");
          const recordIndex = isV2 ? 1 : 0;
          const record = normalizedRecords[recordIndex];

          if (!record?.audioUrl) continue;

          let finalAudioUrl: string | null = null;
          for (const url of record.audioUrls) {
            const local = await downloadToLocalStorage(url, "tracks", `audio/${track.id}.mp3`);
            if (local) {
              finalAudioUrl = local;
              break;
            }
          }
          if (!finalAudioUrl) {
            finalAudioUrl = record.audioUrl;
          }

          let finalCoverUrl: string | null = null;
          for (const url of record.imageUrls) {
            const local = await downloadToLocalStorage(url, "tracks", `covers/${track.id}.jpg`);
            if (local) {
              finalCoverUrl = local;
              break;
            }
          }
          if (!finalCoverUrl) {
            finalCoverUrl = record.imageUrl;
          }

          const durationSec = record.duration != null
            ? Math.round(Number(record.duration))
            : (await getDurationFromFfmpeg(finalAudioUrl)) || 180;

          const { error } = await supabaseAdmin
            .from("tracks")
            .update({
              audio_url: finalAudioUrl,
              cover_url: finalCoverUrl,
              duration: durationSec,
              status: "completed",
              error_message: null,
              suno_audio_id: record.id,
            })
            .eq("id", track.id)
            .eq("user_id", user.id);

          if (!error) {
            completedTrackIds.push(track.id);
          } else {
            console.error(`[suno-check-status] Failed to update track ${track.id}:`, error);
          }
        }

        await markGenerationLogsCompleted(supabaseAdmin, completedTrackIds);
      }

      return new Response(
        JSON.stringify({
          success: true,
          status: taskStatus,
          records: normalizedRecords,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (statusData.status === 404 || statusData.error === "Not Found") {
      return new Response(
        JSON.stringify({ success: false, status: "processing", message: "Still processing, waiting for callback" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    return new Response(
      JSON.stringify({
        success: false,
        status: "processing",
        error: statusData.msg || "API error",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("Error in suno-check-status:", error);
    return new Response(
      JSON.stringify({ success: false, status: "processing", message: "Checking status, waiting for callback" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://apibox.erweima.ai";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "http://api:3000";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const BASE_URL = Deno.env.get("BASE_URL") || "http://localhost";

// Download external file and save to local storage via API (with retry for transient errors)
async function downloadToLocalStorage(
  externalUrl: string,
  bucket: string,
  filePath: string,
  maxRetries = 2
): Promise<string | null> {
  let lastErr: Error | null = null;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      console.log(`Downloading ${externalUrl} → ${bucket}/${filePath} (attempt ${attempt + 1})`);
      const resp = await fetch(externalUrl);
      if (!resp.ok) {
        console.log(`Download failed: ${resp.status}`);
        if (attempt < maxRetries) await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        continue;
      }
      const blob = await resp.blob();
      const buffer = new Uint8Array(await blob.arrayBuffer());
      if (buffer.length < 1000) {
        console.log(`File too small (${buffer.length} bytes), likely invalid`);
        if (attempt < maxRetries) await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        continue;
      }

      const uploadResp = await fetch(
        `${SUPABASE_URL}/storage/v1/object/${bucket}/${filePath}`,
        {
          method: "PUT",
          headers: {
            "Content-Type": blob.type || "application/octet-stream",
            "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
          },
          body: buffer,
        }
      );

      if (!uploadResp.ok) {
        const errText = await uploadResp.text();
        console.log(`Upload to storage failed: ${uploadResp.status} ${errText}`);
        if (attempt < maxRetries) await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        continue;
      }

      const localUrl = `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`;
      console.log(`Saved to local storage: ${localUrl}`);
      return localUrl;
    } catch (err) {
      lastErr = err instanceof Error ? err : new Error(String(err));
      console.error(`Download attempt ${attempt + 1} failed:`, lastErr.message);
      if (attempt < maxRetries) await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
    }
  }
  return null;
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
        // Include "failed" tracks — if Suno says SUCCESS, we can resurrect them.
        // This handles the case when callback never arrived and frontend timed out.
        const { data: matchedTracks } = await supabaseClient
          .from("tracks")
          .select("id, title, description, status")
          .eq("user_id", userId)
          .in("status", ["processing", "pending", "failed"])
          .order("created_at", { ascending: true });

        const tracksWithTask = (matchedTracks || []).filter(
          (t: { description?: string }) => t.description?.includes(`[task_id: ${taskId}]`) || t.description?.includes(`[task_id:${taskId}]`)
        );

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

          // Download audio with fallback chain (try all URLs until one succeeds)
          let finalAudioUrl: string | null = null;
          for (const url of rec.audioUrls) {
            const local = await downloadToLocalStorage(url, "tracks", `audio/${trk.id}.mp3`);
            if (local) { finalAudioUrl = local; break; }
          }
          if (!finalAudioUrl) finalAudioUrl = rec.audioUrl;

          // Download cover with fallback chain
          let finalCoverUrl: string | null = null;
          if (rec.imageUrls.length > 0) {
            for (const url of rec.imageUrls) {
              const local = await downloadToLocalStorage(url, "tracks", `covers/${trk.id}.jpg`);
              if (local) { finalCoverUrl = local; break; }
            }
            if (!finalCoverUrl) finalCoverUrl = rec.imageUrl;
          }

          // API erweima.ai часто возвращает duration: null — fallback 180 (FFmpeg убран — блокировал)
          const durationSec = rec.duration != null ? Math.round(Number(rec.duration)) : 180;

          const { error: updateError } = await supabaseClient
            .from("tracks")
            .update({
              audio_url: finalAudioUrl,
              cover_url: finalCoverUrl,
              duration: durationSec,
              status: "completed",
              error_message: null,
              suno_audio_id: rec.id ? String(rec.id) : null,
            })
            .eq("id", trk.id)
            .eq("user_id", userId);

          if (updateError) {
            console.error(`Error updating track ${trk.id}:`, updateError);
          } else {
            console.log(`Track ${trk.id} (${trk.title}) completed via polling, record[${recordIndex}], suno_audio_id=${rec.id}`);
          }
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