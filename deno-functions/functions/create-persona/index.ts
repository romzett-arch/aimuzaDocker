import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://api.sunoapi.org";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const userClient = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: authHeader } },
    });

    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { 
      personaId,
      trackId, 
      name, 
      description,
      avatarUrl,
      styleTags,
      isPublic,
      clipStart,
      clipEnd,
    } = await req.json();

    console.log(`[Persona] Creating for user ${user.id}, track ${trackId}`);

    if (!trackId || !name) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: trackId, name" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Use admin client to read track (avoids RLS issues with select on tracks)
    const { data: track, error: trackError } = await adminClient
      .from("tracks")
      .select("id, title, description, status, suno_audio_id, user_id")
      .eq("id", trackId)
      .single();

    if (trackError || !track) {
      console.error("[Persona] Track not found:", trackError);
      return new Response(
        JSON.stringify({ error: "Трек не найден" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (track.user_id !== user.id) {
      return new Response(
        JSON.stringify({ error: "Нет доступа к этому треку" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (track.status !== "ready" && track.status !== "completed") {
      return new Response(
        JSON.stringify({ error: "Трек должен быть полностью сгенерирован для создания персоны" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const taskIdMatch = track.description?.match(/\[task_id:\s*([^\]]+)\]/);
    const taskId = taskIdMatch ? taskIdMatch[1].trim() : null;
    const audioId = track.suno_audio_id;

    if (!taskId || !audioId) {
      console.error(`[Persona] Missing Suno IDs for track ${trackId}: taskId=${taskId}, audioId=${audioId}`);
      return new Response(
        JSON.stringify({ error: "Для этого трека недоступна функция создания персоны. Трек был создан до добавления этой функции." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[Persona] Found Suno IDs: taskId=${taskId}, audioId=${audioId}`);

    // Build Suno API payload per docs: https://docs.sunoapi.org/suno-api/generate-persona
    const vocalStart = typeof clipStart === "number" ? clipStart : 0;
    const vocalEnd = typeof clipEnd === "number" ? clipEnd : 30;

    const sunoPayload: Record<string, unknown> = {
      taskId,
      audioId,
      name: name.trim(),
      description: description?.trim() || `Голос из трека "${track.title}"`,
      vocalStart,
      vocalEnd,
    };
    if (styleTags?.trim()) {
      sunoPayload.style = styleTags.trim();
    }

    console.log("[Persona] Sending to Suno API:", JSON.stringify(sunoPayload));

    const sunoResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/generate-persona`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    console.log("[Persona] Suno API response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      const errorMessage = sunoData.msg || "Failed to create persona";
      console.error(`[Persona] Suno API error (code ${sunoData.code}): ${errorMessage}`);
      
      if (personaId) {
        await adminClient
          .from("personas")
          .update({ status: "failed" })
          .eq("id", personaId);
      }

      return new Response(
        JSON.stringify({ error: `Ошибка Suno: ${errorMessage}` }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const sunoPersonaId = sunoData.data?.personaId || sunoData.data?.id;
    
    if (!sunoPersonaId) {
      console.error("[Persona] No persona ID in Suno response:", sunoData);
      return new Response(
        JSON.stringify({ error: "Suno не вернул ID персоны" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[Persona] Created with Suno ID: ${sunoPersonaId}`);

    let savedPersona;
    
    if (personaId) {
      const { data, error } = await adminClient
        .from("personas")
        .update({
          suno_persona_id: sunoPersonaId,
          status: "ready",
          updated_at: new Date().toISOString(),
        })
        .eq("id", personaId)
        .select()
        .single();
      
      if (error) {
        console.error("[Persona] Failed to update persona:", error);
        return new Response(
          JSON.stringify({ error: `Ошибка сохранения: ${error.message}` }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      savedPersona = data;
    } else {
      const { data, error } = await adminClient
        .from("personas")
        .insert({
          user_id: user.id,
          name: name.trim(),
          avatar_url: avatarUrl || null,
          source_track_id: trackId,
          clip_start_time: vocalStart,
          clip_end_time: vocalEnd,
          description: description?.trim() || null,
          style_tags: styleTags?.trim() || null,
          is_public: isPublic || false,
          suno_persona_id: sunoPersonaId,
          status: "ready",
        })
        .select()
        .single();
      
      if (error) {
        console.error("[Persona] Failed to create persona record:", error);
        return new Response(
          JSON.stringify({ error: `Ошибка сохранения: ${error.message}` }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      savedPersona = data;
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        personaId: savedPersona?.id,
        sunoPersonaId,
        message: "Персона успешно создана",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[Persona] Error in create-persona:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Произошла непредвиденная ошибка" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
