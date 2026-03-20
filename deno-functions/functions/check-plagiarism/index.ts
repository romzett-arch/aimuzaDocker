import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { PlagiarismRequest, CheckStep } from "./types.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const MOCK_STEPS: CheckStep[] = [
  { id: "acoustid", name: "AcoustID Fingerprint", database: "MusicBrainz (45M+ треков)", status: "done" },
  { id: "acrcloud", name: "ACRCloud", database: "Глобальная база (100M+ треков)", status: "done" },
  { id: "internal", name: "Внутренняя база", database: "AI Planet Sound", status: "done" },
];

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      throw new Error("Supabase env is not configured");
    }

    const authHeader = req.headers.get("authorization") ?? req.headers.get("Authorization");
    const token = authHeader?.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      return jsonResponse({ success: false, error: "Unauthorized" }, 401);
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    const { trackId, audioUrl }: Partial<PlagiarismRequest> = await req.json();
    const { data: authData, error: authError } = await authClient.auth.getUser(token);
    if (authError || !authData.user) {
      return jsonResponse({ success: false, error: "Unauthorized" }, 401);
    }

    if (!trackId) {
      throw new Error("trackId is required");
    }

    const requesterId = authData.user.id;
    const { data: trackData, error: trackError } = await supabase
      .from("tracks")
      .select("user_id")
      .eq("id", trackId)
      .single();

    if (trackError || !trackData) {
      throw new Error("Track not found");
    }

    const { data: requesterProfile } = await supabase
      .from("profiles")
      .select("role")
      .eq("user_id", requesterId)
      .maybeSingle();

    const isAdmin = requesterProfile?.role === "admin" || requesterProfile?.role === "super_admin";
    if (trackData.user_id !== requesterId && !isAdmin) {
      return jsonResponse({ success: false, error: "Forbidden" }, 403);
    }

    console.log(`[check-plagiarism] Mock success for track: ${trackId}`);

    const checkedAt = new Date().toISOString();
    const processedSteps = MOCK_STEPS.map((step) => ({
      id: step.id,
      name: step.name,
      database: step.database,
      status: step.status,
      matchCount: 0,
    }));

    const { error: updateError } = await supabase
      .from("tracks")
      .update({
        copyright_check_status: "clean",
        plagiarism_check_status: "clean",
        plagiarism_check_result: {
          isClean: true,
          score: 100,
          matches: [],
          steps: processedSteps,
          checkedAt,
          mode: "mock_pass",
          mock: true,
          message: "Проверка плагиата временно отключена. Возвращён успешный результат-заглушка.",
        },
      })
      .eq("id", trackId);

    if (updateError) {
      console.error("[check-plagiarism] Update error:", updateError);
      throw updateError;
    }

    await supabase.from("distribution_logs").insert({
      track_id: trackId,
      user_id: trackData.user_id,
      action: "plagiarism_check_clean",
      stage: "upload",
      details: {
        isClean: true,
        score: 100,
        matchCount: 0,
        audio_url: audioUrl ?? null,
        mock: true,
        steps: processedSteps.map((step) => step.id),
      },
    });

    return jsonResponse({
      success: true,
      isClean: true,
      score: 100,
      matches: [],
      steps: processedSteps,
      mock: true,
      message: "Проверка плагиата временно отключена. Трек автоматически помечен как прошедший проверку.",
    });
  } catch (error) {
    console.error("[check-plagiarism] Error:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return jsonResponse({ success: false, error: message }, 500);
  }
});
