import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { CheckStep } from "./types.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};
const MAX_AUDIO_BYTES = 100 * 1024 * 1024;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function toHex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function resolveAudioUrl(audioUrl: string, supabaseUrl: string): string {
  if (/^https?:\/\//i.test(audioUrl)) return audioUrl;
  return new URL(audioUrl.startsWith("/") ? audioUrl : `/${audioUrl}`, supabaseUrl).toString();
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  let trackId: string | undefined;
  let serviceClient: ReturnType<typeof createClient> | undefined;
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!supabaseUrl || !anonKey || !serviceRoleKey) throw new Error("Supabase env is not configured");

    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return jsonResponse({ success: false, error: "Unauthorized" }, 401);

    const body = await req.json();
    trackId = body?.trackId;
    if (!trackId) return jsonResponse({ success: false, error: "trackId is required" }, 400);

    serviceClient = createClient(supabaseUrl, serviceRoleKey);
    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: authData, error: authError } = await authClient.auth.getUser(token);
    if (authError || !authData.user) return jsonResponse({ success: false, error: "Unauthorized" }, 401);

    const { data: track, error: trackError } = await serviceClient
      .from("tracks")
      .select("id,user_id,title,audio_url")
      .eq("id", trackId)
      .single();
    if (trackError || !track) return jsonResponse({ success: false, error: "Track not found" }, 404);

    const { data: roleRows } = await serviceClient
      .from("user_roles")
      .select("role")
      .eq("user_id", authData.user.id);
    const isStaff = roleRows?.some((row) => ["admin", "moderator", "super_admin"].includes(row.role));
    if (track.user_id !== authData.user.id && !isStaff) {
      return jsonResponse({ success: false, error: "Forbidden" }, 403);
    }
    if (!track.audio_url) throw new Error("У трека отсутствует аудиофайл");

    const audioResponse = await fetch(resolveAudioUrl(track.audio_url, supabaseUrl));
    if (!audioResponse.ok) throw new Error(`Не удалось получить аудио: HTTP ${audioResponse.status}`);
    const declaredSize = Number(audioResponse.headers.get("content-length") || 0);
    if (declaredSize > MAX_AUDIO_BYTES) throw new Error("Аудиофайл превышает лимит 100 МБ");
    const audio = await audioResponse.arrayBuffer();
    if (!audio.byteLength || audio.byteLength > MAX_AUDIO_BYTES) throw new Error("Некорректный размер аудиофайла");

    const hash = toHex(await crypto.subtle.digest("SHA-256", audio));
    const { data: matches, error: matchesError } = await serviceClient
      .from("tracks")
      .select("id,title,performer_name")
      .eq("content_sha256", hash)
      .neq("id", trackId)
      .limit(20);
    if (matchesError) throw matchesError;

    const isClean = !matches?.length;
    const checkedAt = new Date().toISOString();
    const steps: CheckStep[] = [{
      id: "internal_sha256",
      name: "Точное сравнение аудиофайла",
      database: "Внутренняя база AIMUZA",
      status: "done",
    }];
    const result = {
      isClean,
      score: isClean ? 100 : 0,
      matches: matches || [],
      steps: steps.map((step) => ({ ...step, matchCount: matches?.length || 0 })),
      checkedAt,
      mode: "internal_sha256",
      message: isClean
        ? "Точных копий аудиофайла во внутренней базе AIMUZA не найдено. Внешние каталоги не проверялись."
        : "Во внутренней базе AIMUZA найдены точные копии аудиофайла.",
    };

    const { error: updateError } = await serviceClient.from("tracks").update({
      content_sha256: hash,
      copyright_check_status: isClean ? "clean" : "flagged",
      plagiarism_check_status: isClean ? "clean" : "flagged",
      copyright_check_result: result,
      plagiarism_check_result: result,
      copyright_checked_at: checkedAt,
    }).eq("id", trackId);
    if (updateError) throw updateError;

    await serviceClient.from("distribution_logs").insert({
      track_id: trackId,
      user_id: track.user_id,
      action: isClean ? "plagiarism_check_clean" : "plagiarism_check_flagged",
      stage: "upload",
      details: { mode: "internal_sha256", hash, matchCount: matches?.length || 0 },
    });

    return jsonResponse({ success: true, ...result });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("[check-plagiarism] Error:", message);
    if (serviceClient && trackId) {
      await serviceClient.from("tracks").update({
        copyright_check_status: "error",
        plagiarism_check_status: "error",
        plagiarism_check_result: { mode: "internal_sha256", error: message, checkedAt: new Date().toISOString() },
      }).eq("id", trackId);
    }
    return jsonResponse({ success: false, error: message }, 500);
  }
});
