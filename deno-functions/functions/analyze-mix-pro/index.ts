/**
 * D2 Уровень 2: RoEx Tonn API про-анализ микса
 * Возвращает: громкость, тональный баланс, стерео-ширина, клиппинг, DRC
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const ROEX_API_URL = "https://tonn.roexaudio.com";

const MUSICAL_STYLE_MAP: Record<string, string> = {
  rock: "ROCK",
  metal: "METAL",
  pop: "POP",
  electronic: "ELECTRONIC",
  hiphop: "HIP_HOP_GRIME",
  hip_hop: "HIP_HOP_GRIME",
  acoustic: "ACOUSTIC",
  jazz: "JAZZ",
  classical: "ORCHESTRAL",
  orchestral: "ORCHESTRAL",
  ambient: "AMBIENT",
  techno: "TECHNO",
  house: "HOUSE",
  trap: "TRAP",
  dance: "DANCE",
  folk: "FOLK",
  indie: "INDIE_POP",
  rnb: "RNB",
  reggae: "REGGAE",
  latin: "LATIN",
  lo_fi: "LO_FI",
  instrumental: "INSTRUMENTAL",
  other: "POP",
};

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

    const body = await req.json().catch(() => ({}));
    const { audio_url, track_id, musical_style, is_master } = body;

    if (!audio_url?.trim()) {
      return new Response(
        JSON.stringify({ error: "audio_url required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "mix_quality")
      .maybeSingle();

    const config = setting?.value as { enabled?: boolean; price_rub?: number } | null;
    if (!config?.enabled) {
      return new Response(
        JSON.stringify({ error: "mix_quality not enabled" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const price = config.price_rub ?? 10;
    const ROEX_API_KEY = Deno.env.get("ROEX_API_KEY") || (config as any)?.api_key;
    if (!ROEX_API_KEY) {
      return new Response(
        JSON.stringify({ error: "ROEX_API_KEY not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let track: { user_id: string } | null = null;
    let balance = 0;

    if (track_id) {
      const { data: trackData } = await supabase.from("tracks").select("user_id").eq("id", track_id).maybeSingle();
      track = trackData;
      if (!track?.user_id) {
        return new Response(
          JSON.stringify({ error: "Track not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { data: profile } = await supabase.from("profiles").select("balance").eq("user_id", track.user_id).maybeSingle();
      balance = profile?.balance ?? 0;
      if (balance < price) {
        return new Response(
          JSON.stringify({ error: `Недостаточно средств. Нужно: ${price} ₽` }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const newBalance = balance - price;
      const { error: balanceError } = await supabase.from("profiles").update({ balance: newBalance }).eq("user_id", track.user_id);
      if (balanceError) {
        return new Response(
          JSON.stringify({ error: "Ошибка списания баланса" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      await supabase.from("balance_transactions").insert({
        user_id: track.user_id,
        amount: -price,
        type: "addon",
        description: "Про-анализ микса (RoEx)",
        metadata: { track_id, addon: "mix_pro_analysis" },
      });
    }

    const styleKey = (musical_style || "pop").toString().toLowerCase().replace(/\s+/g, "_");
    const roexStyle = MUSICAL_STYLE_MAP[styleKey] || "POP";
    const isMaster = !!is_master;

    const roexBody = {
      mixDiagnosisData: {
        audioFileLocation: audio_url.trim(),
        musicalStyle: roexStyle,
        isMaster,
      },
    };

    const roexUrl = `${ROEX_API_URL}/mixanalysis?key=${encodeURIComponent(ROEX_API_KEY)}`;
    const roexResponse = await fetch(roexUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(roexBody),
    });

    if (!roexResponse.ok) {
      const errText = await roexResponse.text();
      console.warn("[analyze-mix-pro] RoEx error:", roexResponse.status, errText);
      if (track_id && track?.user_id) {
        await supabase.from("profiles").update({ balance: balance + price }).eq("user_id", track.user_id);
        await supabase.from("balance_transactions").insert({
          user_id: track.user_id,
          amount: price,
          type: "refund",
          description: "Возврат: RoEx недоступен",
          metadata: { track_id, addon: "mix_pro_analysis" },
        });
      }
      return new Response(
        JSON.stringify({ error: "RoEx API unavailable" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const roexData = await roexResponse.json();

    if (roexData.error) {
      return new Response(
        JSON.stringify({ error: roexData.info || roexData.message || "RoEx analysis failed" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const mixResult = roexData.mixDiagnosisResults?.payload || roexData;
    const summary = roexData.mixDiagnosisResults?.summary || mixResult.summary;

    const result = {
      integrated_loudness_lufs: mixResult.integrated_loudness_lufs,
      peak_loudness_dbfs: mixResult.peak_loudness_dbfs,
      clipping: mixResult.clipping,
      stereo_field: mixResult.stereo_field,
      phase_issues: mixResult.phase_issues,
      mono_compatible: mixResult.mono_compatible,
      tonal_profile: mixResult.tonal_profile,
      if_master_drc: mixResult.if_master_drc,
      if_master_loudness: mixResult.if_master_loudness,
      if_mix_drc: mixResult.if_mix_drc,
      if_mix_loudness: mixResult.if_mix_loudness,
      mix_style: mixResult.mix_style,
      musical_style: mixResult.musical_style,
      sample_rate: mixResult.sample_rate,
      bit_depth: mixResult.bit_depth,
      summary,
    };

    if (track_id) {
      await supabase
        .from("track_health_reports")
        .upsert(
          {
            track_id,
            mix_pro_result: result,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "track_id" }
        );
    }

    return new Response(
      JSON.stringify({ success: true, result }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[analyze-mix-pro] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
