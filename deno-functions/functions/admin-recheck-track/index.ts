import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://apibox.erweima.ai";

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

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await supabaseClient.auth.getClaims(token);
    
    if (claimsError || !claimsData?.claims?.sub) {
      console.error("Auth error:", claimsError);
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const userId = claimsData.claims.sub;

    // Check if user is admin (roles are in user_roles table, not profiles)
    const { data: roles } = await supabaseAdmin
      .from("user_roles")
      .select("role")
      .eq("user_id", userId);

    const isAdmin = roles?.some(r => r.role === "admin" || r.role === "super_admin");
    if (!isAdmin) {
      return new Response(
        JSON.stringify({ error: "Forbidden: admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { trackId } = await req.json();

    if (!trackId) {
      return new Response(
        JSON.stringify({ error: "Missing trackId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get track data
    const { data: track, error: trackError } = await supabaseAdmin
      .from("tracks")
      .select("*")
      .eq("id", trackId)
      .single();

    if (trackError || !track) {
      return new Response(
        JSON.stringify({ error: "Track not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[Admin Recheck] Track ${trackId}, status: ${track.status}`);

    // Check if track already has permanent audio stored in our Supabase storage
    const supabaseStorageUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const hasLocalAudio = track.audio_url && track.audio_url.includes(supabaseStorageUrl);
    
    if (hasLocalAudio && track.status === "completed") {
      return new Response(
        JSON.stringify({ 
          success: true,
          status: "completed",
          message: "Трек уже готов и сохранён в нашем хранилище",
          audio_url: track.audio_url
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Extract task_id from description
    const taskIdMatch = track.description?.match(/\[task_id:([^\]]+)\]/);
    const taskId = taskIdMatch?.[1]?.trim();

    if (!taskId) {
      // If no task_id but track has audio, it's still usable
      if (track.audio_url) {
        return new Response(
          JSON.stringify({ 
            success: true,
            status: "completed",
            message: "Трек имеет аудио, но task_id не найден. Возможно, был создан вручную.",
            audio_url: track.audio_url
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      return new Response(
        JSON.stringify({ 
          success: false,
          error: "No task_id found in track description",
          message: "Трек не содержит task_id для проверки"
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[Admin Recheck] Checking Suno task ${taskId}`);

    // Check status with Suno API
    const statusResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/record?taskId=${taskId}`, {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
    });

    const statusData = await statusResponse.json();
    console.log(`[Admin Recheck] Suno response:`, JSON.stringify(statusData));

    if (statusData.code === 200 && statusData.data) {
      const records = statusData.data.response?.sunoData || statusData.data.data || [];
      const taskStatus = statusData.data.status;
      
      console.log(`[Admin Recheck] Task status: ${taskStatus}, Records: ${records.length}`);
      
      // Check for completed status with audio
      if (records.length > 0 && records[0].audio_url) {
        const record = records[0];
        
        // Download and store audio permanently
        let permanentAudioUrl = record.audio_url;
        let permanentCoverUrl = record.image_url || track.cover_url;

        try {
          // Download audio
          const audioResponse = await fetch(record.audio_url);
          if (audioResponse.ok) {
            const audioBuffer = await audioResponse.arrayBuffer();
            const audioPath = `${track.user_id}/${trackId}.mp3`;
            
            const { error: audioUploadError } = await supabaseAdmin.storage
              .from("tracks")
              .upload(audioPath, audioBuffer, {
                contentType: "audio/mpeg",
                upsert: true,
              });

            if (!audioUploadError) {
              const { data: audioUrlData } = supabaseAdmin.storage
                .from("tracks")
                .getPublicUrl(audioPath);
              permanentAudioUrl = audioUrlData.publicUrl;
              console.log(`[Admin Recheck] Audio saved: ${permanentAudioUrl}`);
            } else {
              console.error(`[Admin Recheck] Audio upload error:`, audioUploadError);
            }
          }

          // Download cover if available
          if (record.image_url) {
            const coverResponse = await fetch(record.image_url);
            if (coverResponse.ok) {
              const coverBuffer = await coverResponse.arrayBuffer();
              const coverPath = `${track.user_id}/${trackId}-cover.jpg`;
              
              const { error: coverUploadError } = await supabaseAdmin.storage
                .from("tracks")
                .upload(coverPath, coverBuffer, {
                  contentType: "image/jpeg",
                  upsert: true,
                });

              if (!coverUploadError) {
                const { data: coverUrlData } = supabaseAdmin.storage
                  .from("tracks")
                  .getPublicUrl(coverPath);
                permanentCoverUrl = coverUrlData.publicUrl;
                console.log(`[Admin Recheck] Cover saved: ${permanentCoverUrl}`);
              }
            }
          }
        } catch (downloadError) {
          console.error(`[Admin Recheck] Download error:`, downloadError);
          // Continue with original URLs if download fails
        }

        // Update track with audio URL
        const { error: updateError } = await supabaseAdmin
          .from("tracks")
          .update({
            audio_url: permanentAudioUrl,
            cover_url: permanentCoverUrl,
            duration: record.duration ? Math.round(record.duration) : null,
            status: "completed",
            error_message: null,
            suno_audio_id: record.id || null,
          })
          .eq("id", trackId);

        if (updateError) {
          console.error("[Admin Recheck] Error updating track:", updateError);
          return new Response(
            JSON.stringify({ 
              success: false,
              error: updateError.message
            }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        return new Response(
          JSON.stringify({ 
            success: true,
            status: "completed",
            message: "Трек успешно обновлён!",
            audio_url: permanentAudioUrl
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      // Check for failed status
      if (taskStatus === "GENERATE_AUDIO_FAILED" || taskStatus === "FAILED" || taskStatus === "ERROR") {
        const errorMessage = statusData.data.fail_reason || statusData.data.error_message || "Генерация отклонена сервисом";
        
        await supabaseAdmin
          .from("tracks")
          .update({
            status: "failed",
            error_message: errorMessage,
          })
          .eq("id", trackId);

        return new Response(
          JSON.stringify({ 
            success: false,
            status: "failed",
            message: `Ошибка генерации: ${errorMessage}`
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Still processing
      return new Response(
        JSON.stringify({ 
          success: false,
          status: taskStatus || "processing",
          message: `Статус: ${taskStatus}. Трек ещё генерируется.`
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    // API returned error or no data - check if it's a 404 (task expired)
    if (statusData.status === 404 || statusData.error === "Not Found") {
      // Task no longer exists on Suno servers - check if we have local audio
      if (track.audio_url) {
        // We have audio, just update status to completed
        await supabaseAdmin
          .from("tracks")
          .update({
            status: "completed",
            error_message: null,
          })
          .eq("id", trackId);

        return new Response(
          JSON.stringify({ 
            success: true,
            status: "completed",
            message: "Задача удалена с сервера Suno, но аудио доступно. Статус обновлён.",
            audio_url: track.audio_url
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      
      return new Response(
        JSON.stringify({ 
          success: false,
          status: "expired",
          message: "Задача удалена с сервера Suno и аудио недоступно. Генерация не может быть восстановлена."
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ 
        success: false,
        status: "unknown",
        message: `Suno API ответил: ${statusData.msg || statusData.error || "Unknown error"}`,
        raw: statusData
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[Admin Recheck] Error:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
