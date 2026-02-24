import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Replicate MTG music-classifiers: musicnn-mtat даёт теги настроения (MagnaTagATune)
const REPLICATE_MTG_VERSION = "fb1f50036eaaf8918ca419f236b0b48d28bc3ef20b4b3f915cf9ed1a3d3064ab";

interface ClassifyResult {
  mood: string | null;
  energy: number | null;
}

function parseReplicateOutput(output: unknown): ClassifyResult {
  const result: ClassifyResult = { mood: null, energy: null };

  // output может быть URL файла или inline JSON
  if (typeof output === "string") {
    // Если это URL — не будем фетчить в edge (timeout), используем fallback
    if (output.startsWith("http")) {
      return result;
    }
    try {
      const parsed = JSON.parse(output);
      return extractMoodEnergy(parsed);
    } catch {
      return result;
    }
  }

  if (output && typeof output === "object") {
    return extractMoodEnergy(output as Record<string, unknown>);
  }

  return result;
}

function extractMoodEnergy(data: Record<string, unknown>): ClassifyResult {
  const result: ClassifyResult = { mood: null, energy: null };

  // Варианты формата MTG: { predictions: [...], tags: [...], output: {...} }
  const predictions = (data.predictions ?? data.tags ?? data.output ?? data) as unknown;
  if (Array.isArray(predictions)) {
    const tags = predictions
      .filter((t): t is { tag?: string; name?: string; label?: string; score?: number } => t && typeof t === "object")
      .map((t) => ({
        name: (t.tag ?? t.name ?? t.label ?? "").toString().toLowerCase(),
        score: typeof t.score === "number" ? t.score : 0.5,
      }))
      .filter((t) => t.name)
      .sort((a, b) => b.score - a.score)
      .slice(0, 5);

    if (tags.length > 0) {
      result.mood = tags.map((t) => t.name).join(", ");
      // Эвристика energy: energetic, aggressive, calm, sad и т.д.
      const energyTags = ["energetic", "aggressive", "powerful", "intense", "upbeat"];
      const calmTags = ["calm", "relaxing", "peaceful", "soft", "mellow"];
      const energyIdx = tags.findIndex((t) => energyTags.some((e) => t.name.includes(e)));
      const calmIdx = tags.findIndex((t) => calmTags.some((c) => t.name.includes(c)));
      if (energyIdx >= 0) result.energy = 0.7 + (tags[energyIdx]?.score ?? 0.5) * 0.3;
      else if (calmIdx >= 0) result.energy = 0.2 + (1 - (tags[calmIdx]?.score ?? 0.5)) * 0.2;
      else result.energy = 0.5;
    }
  }

  // Альтернативный формат: { mood: "...", energy: 0.5 }
  if (!result.mood && typeof data.mood === "string") result.mood = data.mood;
  if (result.energy == null && typeof data.energy === "number") result.energy = data.energy;

  return result;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const replicateToken = Deno.env.get("REPLICATE_API_TOKEN");
    if (!replicateToken) {
      return new Response(
        JSON.stringify({ success: false, error: "REPLICATE_API_TOKEN not configured" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json() as { audio_url: string; track_id: string; source?: "upload" | "generated" };
    const { audio_url, track_id, source = "upload" } = body;

    const authHeader = req.headers.get("Authorization");
    const isInternalCall =
      req.headers.get("x-internal-call") === "true" &&
      authHeader?.startsWith("Bearer ") &&
      authHeader.replace("Bearer ", "") === supabaseServiceKey;
    if (isInternalCall) {
      // Вызов из suno-callback: проверяем что трек существует
      const { data: track } = await supabase.from("tracks").select("id, user_id").eq("id", track_id).maybeSingle();
      if (!track) {
        return new Response(
          JSON.stringify({ error: "Track not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    } else {
      if (!authHeader?.startsWith("Bearer ")) {
        return new Response(
          JSON.stringify({ error: "Authorization required" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      const token = authHeader.replace("Bearer ", "");
      const { data: { user }, error: authError } = await supabase.auth.getUser(token);
      if (authError || !user) {
        return new Response(
          JSON.stringify({ error: "Invalid token" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      // Проверяем что трек принадлежит пользователю (для upload)
      const { data: track } = await supabase.from("tracks").select("id").eq("id", track_id).eq("user_id", user.id).maybeSingle();
      if (!track) {
        return new Response(
          JSON.stringify({ error: "Track not found or access denied" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }


    if (!audio_url || !track_id) {
      return new Response(
        JSON.stringify({ error: "audio_url and track_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Проверяем настройки audio_classification
    const { data: settingsRow } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "audio_classification")
      .maybeSingle();

    const settings = (settingsRow?.value as Record<string, unknown>) ?? {};
    const enabled = settings.enabled === true;
    const autoUploads = settings.auto_classify_uploads !== false;
    const autoGenerated = settings.auto_classify_generated === true;

    if (!enabled) {
      return new Response(
        JSON.stringify({ success: false, skipped: true, reason: "audio_classification disabled" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (source === "upload" && !autoUploads) {
      return new Response(
        JSON.stringify({ success: false, skipped: true, reason: "auto_classify_uploads disabled" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (source === "generated" && !autoGenerated) {
      return new Response(
        JSON.stringify({ success: false, skipped: true, reason: "auto_classify_generated disabled" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Classifying audio for track ${track_id}, source=${source}`);

    const createRes = await fetch("https://api.replicate.com/v1/predictions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${replicateToken}`,
        "Content-Type": "application/json",
        Prefer: "wait",
      },
      body: JSON.stringify({
        version: REPLICATE_MTG_VERSION,
        input: {
          audio: audio_url,
          model_type: "musicnn-mtat",
        },
      }),
    });

    if (!createRes.ok) {
      const errText = await createRes.text();
      console.error("Replicate API error:", createRes.status, errText);
      return new Response(
        JSON.stringify({ success: false, error: `Replicate API: ${createRes.status}` }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const prediction = await createRes.json() as {
      status: string;
      output?: unknown;
      error?: string;
    };

    if (prediction.status !== "succeeded") {
      return new Response(
        JSON.stringify({ success: false, error: prediction.error ?? `Status: ${prediction.status}` }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let classifyResult = parseReplicateOutput(prediction.output);

    // Если output — URL файла, пробуем загрузить (с коротким timeout)
    if (!classifyResult.mood && typeof prediction.output === "string" && prediction.output.startsWith("http")) {
      try {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 5000);
        const fileRes = await fetch(prediction.output as string, { signal: ctrl.signal });
        clearTimeout(t);
        if (fileRes.ok) {
          const text = await fileRes.text();
          const parsed = JSON.parse(text) as Record<string, unknown>;
          classifyResult = extractMoodEnergy(parsed);
        }
      } catch {
        // Игнорируем
      }
    }

    const updatePayload: Record<string, unknown> = {
      ai_classified_at: new Date().toISOString(),
    };
    if (classifyResult.mood) updatePayload.mood = classifyResult.mood;
    if (classifyResult.energy != null) updatePayload.energy = classifyResult.energy;

    const { error: updateError } = await supabase
      .from("tracks")
      .update(updatePayload)
      .eq("id", track_id);

    if (updateError) {
      console.error("Failed to update track:", updateError);
      return new Response(
        JSON.stringify({ success: false, error: "Database update failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        mood: classifyResult.mood,
        energy: classifyResult.energy,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("classify-audio error:", msg);
    return new Response(
      JSON.stringify({ success: false, error: msg }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
