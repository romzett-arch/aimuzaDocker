/**
 * D3 Фаза 2: Вычисление audio_embedding для трека
 * Вызывает Replicate (ImageBind/CLAP), сохраняет в tracks.audio_embedding
 *
 * Что нужно для работы:
 * - REPLICATE_API_TOKEN в .env
 * - pgvector + колонка audio_embedding (миграция 052)
 * - similar_tracks.method = "embeddings" для использования
 *
 * Модели: daanelson/imagebind или anotherjesse/imagebind_batch
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// anotherjesse/imagebind_batch — быстрый, ~1 сек
const IMAGEBIND_VERSION = "d404baadb6a9d67e3e602c9d7feb5c7c9d6883c1289453c9943be71b3cd26043";

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Authorization required" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = (await req.json()) as { track_id: string };
    const { track_id } = body;
    if (!track_id) {
      return new Response(
        JSON.stringify({ error: "track_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, audio_url, user_id")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      return new Response(
        JSON.stringify({ error: "Track not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!track.audio_url) {
      return new Response(
        JSON.stringify({ error: "Track has no audio" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const replicateToken = Deno.env.get("REPLICATE_API_TOKEN");
    if (!replicateToken) {
      return new Response(
        JSON.stringify({ error: "REPLICATE_API_TOKEN not configured" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const createRes = await fetch("https://api.replicate.com/v1/predictions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${replicateToken}`,
        "Content-Type": "application/json",
        Prefer: "wait",
      },
      body: JSON.stringify({
        version: IMAGEBIND_VERSION,
        input: {
          audio: track.audio_url,
          modality: "audio",
        },
      }),
    });

    if (!createRes.ok) {
      const errText = await createRes.text();
      console.warn("[compute-audio-embedding] Replicate error:", createRes.status, errText);
      return new Response(
        JSON.stringify({ error: "Embedding service unavailable", details: errText.substring(0, 200) }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const prediction = await createRes.json();
    const output = prediction.output;

    if (!Array.isArray(output) || output.length !== 512) {
      return new Response(
        JSON.stringify({ error: "Invalid embedding", length: output?.length }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const embeddingStr = `[${output.join(",")}]`;

    const { error: updateError } = await supabase
      .from("tracks")
      .update({ audio_embedding: embeddingStr })
      .eq("id", track_id);

    if (updateError) {
      console.error("[compute-audio-embedding] Update error:", updateError);
      return new Response(
        JSON.stringify({ error: "Failed to save embedding" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, track_id }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[compute-audio-embedding] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
