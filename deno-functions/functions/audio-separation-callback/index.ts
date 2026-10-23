import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const corsHeaders = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
function json(body: Record<string, unknown>, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
function record(value: unknown): Record<string, any> { return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : {}; }
function string(value: unknown) { return typeof value === "string" ? value : ""; }
async function sign(id: string, secret: string) { const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]); const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(id)); return Array.from(new Uint8Array(sig), b => b.toString(16).padStart(2, "0")).join(""); }
function same(a: string, b: string) { if (a.length !== b.length) return false; let diff = 0; for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i); return diff === 0; }
async function copyAudio(client: any, sourceUrl: string, separationId: string, kind: "vocal" | "instrumental") {
  const response = await fetch(sourceUrl); if (!response.ok) throw new Error(`Не удалось скачать ${kind === "vocal" ? "вокал" : "инструментал"}`);
  const bytes = new Uint8Array(await response.arrayBuffer()); if (bytes.length < 1024) throw new Error("Suno вернул пустой аудиофайл");
  const mime = response.headers.get("content-type")?.split(";")[0] || "audio/mpeg"; const extension = mime.includes("wav") ? "wav" : mime.includes("ogg") ? "ogg" : "mp3";
  const path = `separations/${separationId}/${kind}.${extension}`; const { error } = await client.storage.from("tracks").upload(path, bytes, { contentType: mime, upsert: true }); if (error) throw error;
  return client.storage.from("tracks").getPublicUrl(path).data.publicUrl;
}
serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders }); if (req.method !== "POST") return json({ code: 405, msg: "Method not allowed" }, 405);
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""; const client = createClient(Deno.env.get("SUPABASE_URL") || "", serviceKey); let separation: any;
  try {
    const url = new URL(req.url); const id = url.searchParams.get("separation_id") || ""; const token = url.searchParams.get("token") || "";
    if (!id || !token || !same(await sign(id, serviceKey), token)) return json({ code: 401, msg: "Unauthorized" }, 401);
    const { data, error } = await client.from("audio_separations").select("id,user_id,track_id,status,price_rub,result_urls").eq("id", id).maybeSingle(); if (error || !data) return json({ code: 404, msg: "Operation not found" }, 404); separation = data;
    if (separation.status === "completed" || separation.status === "failed") return json({ code: 200, msg: "success" });
    const payload = await req.json(); const callbackData = record(payload?.data); const info = record(callbackData.vocal_removal_info); const callbackTask = string(callbackData.taskId) || string(callbackData.task_id); const knownTask = string(record(separation.result_urls).provider_task_id);
    if (knownTask && callbackTask && knownTask !== callbackTask) return json({ code: 409, msg: "Task mismatch" }, 409);
    const vocalUrl = string(info.vocal_url); const instrumentalUrl = string(info.instrumental_url); const failed = Number(payload?.code) !== 200 || (!vocalUrl && !instrumentalUrl);
    if (failed) {
      const { data: claimed } = await client.from("audio_separations").update({ status: "refunding", error_message: string(payload?.msg) || "Suno не смог разделить трек" }).eq("id", id).in("status", ["pending", "processing", "finalizing"]).select("id").maybeSingle(); if (!claimed) return json({ code: 200, msg: "success" });
      const amount = Number(separation.price_rub || 0); let refunded = false; if (amount > 0) { const { error: refundError } = await client.rpc("refund_addon_service", { p_user_id: separation.user_id, p_amount: amount, p_description: "Возврат за неуспешное разделение вокала", p_metadata: { separation_id: id } }); refunded = !refundError; }
      await client.from("audio_separations").update({ status: "failed", error_message: refunded ? "Не удалось обработать трек. Деньги возвращены." : "Не удалось обработать трек." }).eq("id", id); return json({ code: 200, msg: "success" });
    }
    await client.from("audio_separations").update({ status: "finalizing" }).eq("id", id).in("status", ["pending", "processing"]);
    const [vocal, instrumental] = await Promise.all([copyAudio(client, vocalUrl, id, "vocal"), copyAudio(client, instrumentalUrl, id, "instrumental")]);
    await client.from("audio_separations").update({ status: "completed", error_message: null, result_urls: { vocal_url: vocal, instrumental_url: instrumental, origin_url: string(info.origin_url), provider_task_id: callbackTask || knownTask }, updated_at: new Date().toISOString() }).eq("id", id);
    await client.from("notifications").insert({ user_id: separation.user_id, type: "generation_completed", title: "Вокал и инструментал готовы", message: "Обе дорожки сохранены в вашей библиотеке", target_type: "track", target_id: separation.track_id }); return json({ code: 200, msg: "success" });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Ошибка обработки callback"; console.error("audio-separation-callback failed:", error);
    if (separation?.id) await client.from("audio_separations").update({ status: "processing", error_message: message }).eq("id", separation.id).eq("status", "finalizing"); return json({ code: 500, msg: message }, 500);
  }
});
