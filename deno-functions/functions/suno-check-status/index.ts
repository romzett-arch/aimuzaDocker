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