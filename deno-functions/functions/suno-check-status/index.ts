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

// Download external file and save to local storage via API
async function downloadToLocalStorage(
  externalUrl: string,
  bucket: string,
  filePath: string
): Promise<string | null> {
  try {
    console.log(`Downloading ${externalUrl} → ${bucket}/${filePath}`);
    const resp = await fetch(externalUrl);
    if (!resp.ok) {
      console.log(`Download failed: ${resp.status}`);
      return null;
    }
    const blob = await resp.blob();
    const buffer = new Uint8Array(await blob.arrayBuffer());

    // Upload to local storage API (PUT for upsert)
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
      return null;
    }

    const localUrl = `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`;
    console.log(`Saved to local storage: ${localUrl}`);
    return localUrl;
  } catch (err) {
    console.error(`Error downloading to storage:`, err);
    return null;
  }
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
      
      // Check for failed status - handle GENERATE_AUDIO_FAILED and other failure states
      if (taskStatus === "GENERATE_AUDIO_FAILED" || taskStatus === "FAILED" || taskStatus === "ERROR") {
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
      
      // Suno record-info returns camelCase fields (audioUrl, imageUrl)
      // while callback uses snake_case (audio_url, image_url)
      // Normalize to handle both formats
      const normalizedRecords = records.map((r: Record<string, unknown>) => {
        const rawAudio = r.audioUrl || r.audio_url || r.source_audio_url || r.sourceAudioUrl;
        const audioUrl = (typeof rawAudio === "string" && rawAudio.startsWith("http")) ? rawAudio : null;
        return {
          audioUrl,
          imageUrl: r.imageUrl || r.image_url || r.source_image_url || r.sourceImageUrl,
          duration: r.duration,
          id: r.id,
        };
      });

      if (normalizedRecords.length > 0 && normalizedRecords.some((r: { audioUrl: string | null }) => r.audioUrl)) {
        // Find ALL tracks matching this task_id (both v1 and v2)
        const { data: matchedTracks } = await supabaseClient
          .from("tracks")
          .select("id, title, description")
          .eq("user_id", userId)
          .in("status", ["processing", "pending"])
          .order("created_at", { ascending: true });

        // Filter to tracks that have this task_id
        const tracksWithTask = (matchedTracks || []).filter(
          (t: { description?: string }) => t.description?.includes(`[task_id: ${taskId}]`) || t.description?.includes(`[task_id:${taskId}]`)
        );

        console.log(`Found ${tracksWithTask.length} tracks matching task_id ${taskId}`);

        // Match each DB track to its Suno record by title version (v1→index 0, v2→index 1).
        // When a specific trackId is requested, also update the paired track if it's still pending,
        // so both tracks get processed in a single check-status call.
        for (const trk of tracksWithTask) {

          // Determine which Suno record to use based on title version
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
          
          // Download audio to local storage
          let finalAudioUrl = String(rec.audioUrl);
          const localAudio = await downloadToLocalStorage(
            finalAudioUrl,
            "tracks",
            `audio/${trk.id}.mp3`
          );
          if (localAudio) finalAudioUrl = localAudio;

          // Download cover to local storage
          let finalCoverUrl: string | null = rec.imageUrl ? String(rec.imageUrl) : null;
          if (finalCoverUrl) {
            const localCover = await downloadToLocalStorage(
              finalCoverUrl,
              "tracks",
              `covers/${trk.id}.jpg`
            );
            if (localCover) finalCoverUrl = localCover;
          }

          const { error: updateError } = await supabaseClient
            .from("tracks")
            .update({
              audio_url: finalAudioUrl,
              cover_url: finalCoverUrl,
              duration: rec.duration ? Math.round(Number(rec.duration)) : null,
              status: "completed",
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