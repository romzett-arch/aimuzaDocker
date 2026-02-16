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
      const normalizedRecords = records.map((r: Record<string, unknown>) => ({
        audioUrl: r.audioUrl || r.audio_url || r.source_audio_url || r.sourceAudioUrl,
        imageUrl: r.imageUrl || r.image_url || r.source_image_url || r.sourceImageUrl,
        duration: r.duration,
        id: r.id,
      }));

      // Check if ANY record has a real audio URL (not empty string, null, undefined)
      const hasAnyAudio = normalizedRecords.some(
        (r: { audioUrl: unknown }) => r.audioUrl && String(r.audioUrl) !== "" && String(r.audioUrl) !== "null"
      );

      if (normalizedRecords.length > 0 && hasAnyAudio) {
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

        // Update each track with corresponding Suno record (by order: first→v1, second→v2)
        // Download files to local storage for persistent access
        // CRITICAL: Only update tracks where the corresponding record has a valid audio URL
        for (let i = 0; i < tracksWithTask.length && i < normalizedRecords.length; i++) {
          const rec = normalizedRecords[i];
          const trk = tracksWithTask[i];
          
          // CRITICAL: Skip records without valid audio URL
          // When status is FIRST_SUCCESS, only one of two records has audio
          const rawAudioUrl = rec.audioUrl ? String(rec.audioUrl) : "";
          if (!rawAudioUrl || rawAudioUrl === "" || rawAudioUrl === "null" || rawAudioUrl === "undefined") {
            console.log(`Track ${trk.id} (${trk.title}) — no audio URL yet, skipping (status: ${taskStatus})`);
            continue;
          }
          
          // Download audio to local storage
          let finalAudioUrl = rawAudioUrl;
          const localAudio = await downloadToLocalStorage(
            finalAudioUrl,
            "tracks",
            `audio/${trk.id}.mp3`
          );
          if (localAudio) finalAudioUrl = localAudio;

          // Download cover to local storage
          let finalCoverUrl: string | null = rec.imageUrl ? String(rec.imageUrl) : null;
          if (finalCoverUrl && (finalCoverUrl === "null" || finalCoverUrl === "undefined")) {
            finalCoverUrl = null;
          }
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
            })
            .eq("id", trk.id)
            .eq("user_id", userId);

          if (updateError) {
            console.error(`Error updating track ${trk.id}:`, updateError);
          } else {
            console.log(`Track ${trk.id} (${trk.title}) completed via polling with local storage`);
          }
        }
      } else if (normalizedRecords.length > 0) {
        console.log(`Task ${taskId}: records exist but no audio URLs ready yet (status: ${taskStatus})`);
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