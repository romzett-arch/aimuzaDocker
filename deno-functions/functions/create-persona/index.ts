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
    if (!authHeader) {
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

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
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
      isPublic
    } = await req.json();

    console.log(`Creating persona for user ${user.id}, track ${trackId}`);

    if (!trackId || !name) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: trackId, name" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get track info to extract taskId and audioId
    const { data: track, error: trackError } = await supabaseClient
      .from("tracks")
      .select("id, title, description, status, suno_audio_id")
      .eq("id", trackId)
      .eq("user_id", user.id)
      .single();

    if (trackError || !track) {
      console.error("Track not found:", trackError);
      return new Response(
        JSON.stringify({ error: "Трек не найден" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Allow "ready" or "completed" status
    if (track.status !== "ready" && track.status !== "completed") {
      return new Response(
        JSON.stringify({ error: "Трек должен быть полностью сгенерирован для создания персоны" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Extract taskId from track description (stored in format [task_id: {taskId}])
    const taskIdMatch = track.description?.match(/\[task_id:\s*([^\]]+)\]/);
    const taskId = taskIdMatch ? taskIdMatch[1].trim() : null;

    // Get audioId from track (stored as suno_audio_id)
    const audioId = track.suno_audio_id;

    if (!taskId || !audioId) {
      console.error(`Missing Suno IDs for track ${trackId}: taskId=${taskId}, audioId=${audioId}`);
      return new Response(
        JSON.stringify({ error: "Для этого трека недоступна функция создания персоны. Трек был создан до добавления этой функции." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Found Suno IDs: taskId=${taskId}, audioId=${audioId}`);

    // Call Suno API to create persona
    const sunoPayload = {
      taskId,
      audioId,
      name: name.trim(),
      description: description?.trim() || `Голос из трека "${track.title}"`
    };

    console.log("Sending to Suno API:", JSON.stringify(sunoPayload));

    const sunoResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/generate-persona`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    console.log("Suno API response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      const errorMessage = sunoData.msg || "Failed to create persona";
      console.error(`Suno API error: ${errorMessage}`);
      
      // Update persona status to failed if it exists
      if (personaId) {
        await supabaseClient
          .from("personas")
          .update({ status: "failed" })
          .eq("id", personaId)
          .eq("user_id", user.id);
      }

      return new Response(
        JSON.stringify({ error: `Ошибка Suno: ${errorMessage}` }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Extract persona ID from response
    const sunoPersonaId = sunoData.data?.personaId || sunoData.data?.id;
    
    if (!sunoPersonaId) {
      console.error("No persona ID in Suno response:", sunoData);
      return new Response(
        JSON.stringify({ error: "Suno не вернул ID персоны" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Persona created with Suno ID: ${sunoPersonaId}`);

    // If personaId provided, update existing record
    // Otherwise create new record
    let savedPersona;
    
    if (personaId) {
      const { data, error } = await supabaseClient
        .from("personas")
        .update({
          suno_persona_id: sunoPersonaId,
          status: "ready",
          updated_at: new Date().toISOString()
        })
        .eq("id", personaId)
        .eq("user_id", user.id)
        .select()
        .single();
      
      if (error) {
        console.error("Failed to update persona:", error);
      }
      savedPersona = data;
    } else {
      const { data, error } = await supabaseClient
        .from("personas")
        .insert({
          user_id: user.id,
          name: name.trim(),
          avatar_url: avatarUrl || null,
          source_track_id: trackId,
          clip_start_time: 0,
          clip_end_time: 30,
          description: description?.trim() || null,
          style_tags: styleTags?.trim() || null,
          is_public: isPublic || false,
          suno_persona_id: sunoPersonaId,
          status: "ready"
        })
        .select()
        .single();
      
      if (error) {
        console.error("Failed to create persona record:", error);
      }
      savedPersona = data;
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        personaId: savedPersona?.id,
        sunoPersonaId,
        message: "Персона успешно создана" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in create-persona:", error);
    return new Response(
      JSON.stringify({ error: "Произошла непредвиденная ошибка" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
