import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { recoverSeparation } from "./recover-separation.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};
const SUNO_VOCAL_REMOVAL_URL = "https://apibox.erweima.ai/api/v1/vocal-removal/generate";
const SERVICE_NAME = "vocal_separation";

class RequestError extends Error { constructor(message: string, readonly status: number) { super(message); } }
function json(body: Record<string, unknown>, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
function text(value: unknown) { return typeof value === "string" ? value.trim() : ""; }
function taskIdFromDescription(description: string | null) { return description?.match(/\[task_id:\s*([^\]]+)\]/i)?.[1]?.trim() || ""; }
async function signCallback(separationId: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(separationId));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let userId = ""; let separationId = ""; let debitedAmount = 0; let admin: any;
  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) throw new RequestError("Необходима авторизация", 401);
    const url = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    admin = createClient(url, serviceKey);
    const { data: { user }, error: authError } = await admin.auth.getUser(authorization.slice(7));
    if (authError || !user) throw new RequestError("Неверный токен авторизации", 401);
    userId = user.id;
    const body = await req.json(); const trackId = text(body?.track_id);
    if (!trackId) throw new RequestError("Выберите готовый трек", 422);
    const { data: track, error: trackError } = await admin.from("tracks").select("id,user_id,title,description,audio_url,suno_audio_id,status").eq("id", trackId).maybeSingle();
    if (trackError || !track) throw new RequestError("Трек не найден", 404);
    if (track.user_id !== userId) throw new RequestError("Нет доступа к треку", 403);
    // Status checks stop here, before all billing and task creation code.
    if (body.action === 'status') {
      const { data: job, error } = await admin.from('audio_separations').select('id,status,result_urls').eq('track_id', trackId).eq('user_id', userId).order('created_at', { ascending: false }).limit(1).maybeSingle();
      if (error) throw new Error('Не удалось прочитать состояние разделения');
      const taskId = text(job?.result_urls?.provider_task_id);
      if (job && taskId && ['pending', 'processing', 'finalizing'].includes(job.status)) {
        const apiKey = Deno.env.get('SUNO_API_KEY');
        if (!apiKey) throw new Error('Сервис разделения временно недоступен');
        const token = await signCallback(job.id, serviceKey);
        await recoverSeparation({ taskId, apiKey, callbackUrl: `http://127.0.0.1:8081/functions/v1/audio-separation-callback?separation_id=${encodeURIComponent(job.id)}&token=${token}` });
      }
      return json({ success: true });
    }
    if (track.status !== "completed" || !track.audio_url) throw new RequestError("Разделение доступно для готового трека", 422);
    const { data: activeJob } = await admin.from("audio_separations").select("id,status").eq("track_id", trackId).in("status", ["pending", "processing", "finalizing"]).maybeSingle();
    if (activeJob) return json({ success: true, separation_id: activeJob.id, status: activeJob.status, reused: true }, 202);
    const { data: debitRows, error: debitError } = await admin.rpc("debit_addon_service", {
      p_user_id: userId, p_service_name: SERVICE_NAME, p_description: `Разделение вокала: ${track.title || "трек"}`, p_metadata: { service_name: SERVICE_NAME, track_id: trackId },
    });
    if (debitError) { const insufficient = /insufficient balance/i.test(debitError.message || ""); throw new RequestError(insufficient ? "Недостаточно средств на балансе" : "Услуга временно недоступна", insufficient ? 402 : 503); }
    const debit = debitRows?.[0] || {}; debitedAmount = Number(debit.amount_debited || 0);
    // `vocal` is the canonical legacy-compatible value.  The table predates
    // Studio and some installations still retain its original type constraint.
    const { data: separation, error: createError } = await admin.from("audio_separations").insert({ user_id: userId, track_id: trackId, type: "vocal", status: "processing", source_url: track.audio_url, result_urls: {}, price_rub: debitedAmount }).select("id").single();
    if (createError || !separation?.id) throw new Error("Не удалось создать задачу разделения");
    separationId = separation.id;
    const apiKey = Deno.env.get("SUNO_API_KEY"); if (!apiKey) throw new Error("Suno API временно недоступен");
    const baseUrl = (Deno.env.get("BASE_URL") || "https://aimuza.ru").replace(/\/$/, "");
    const callbackToken = await signCallback(separationId, serviceKey);
    const callBackUrl = `${baseUrl}/functions/v1/audio-separation-callback?separation_id=${encodeURIComponent(separationId)}&token=${encodeURIComponent(callbackToken)}`;
    const sourceTaskId = taskIdFromDescription(track.description);
    const providerPayload: Record<string, string> = { callBackUrl, type: "separate_vocal" };
    if (sourceTaskId && track.suno_audio_id) { providerPayload.taskId = sourceTaskId; providerPayload.audioId = track.suno_audio_id; } else { providerPayload.audioUrl = track.audio_url; }
    const providerResponse = await fetch(SUNO_VOCAL_REMOVAL_URL, { method: "POST", headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" }, body: JSON.stringify(providerPayload) });
    const providerResult = await providerResponse.json().catch(() => ({}));
    const providerTaskId = text(providerResult?.data?.taskId) || text(providerResult?.data?.task_id);
    if (!providerResponse.ok || Number(providerResult?.code) !== 200 || !providerTaskId) throw new Error(text(providerResult?.msg) || "Suno не принял задачу разделения");
    await admin.from("audio_separations").update({ result_urls: { provider_task_id: providerTaskId } }).eq("id", separationId);
    return json({ success: true, separation_id: separationId, status: "processing", amount_debited: debitedAmount }, 202);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Не удалось запустить разделение вокала";
    const status = error instanceof RequestError ? error.status : 500; console.error("audio-separation failed:", error);
    if (admin && separationId) await admin.from("audio_separations").update({ status: "failed", error_message: message }).eq("id", separationId);
    let refunded = false;
    if (admin && userId && debitedAmount > 0) { const { error: refundError } = await admin.rpc("refund_addon_service", { p_user_id: userId, p_amount: debitedAmount, p_description: "Возврат за неуспешное разделение вокала", p_metadata: { service_name: SERVICE_NAME, separation_id: separationId || null } }); refunded = !refundError; }
    return json({ error: message, refunded }, status);
  }
});
