import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const API_BASE = "https://api.sunoapi.org";
const PROMPT_LIMIT = 200;

type LyricsResult = { text: string; title: string };

async function pollLyricsResult(taskId: string, apiKey: string, maxAttempts = 30): Promise<LyricsResult | null> {
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    const response = await fetch(`${API_BASE}/api/v1/lyrics/record-info?taskId=${encodeURIComponent(taskId)}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    const result = await response.json();

    if (result.code === 200 && result.data?.status === "SUCCESS") {
      const item = result.data.response?.data?.[0];
      return {
        text: item?.text || result.data.text || "",
        title: item?.title || result.data.title || "",
      };
    }
    if (result.data?.status === "FAILED") {
      throw new Error(result.data?.errorMessage || "Не удалось создать текст");
    }
  }
  return null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const startedAt = Date.now();
  const requestId = crypto.randomUUID();
  let userId: string | null = null;
  let debitedAmount = 0;
  let generationLogId: string | null = null;
  let adminClient: ReturnType<typeof createClient> | null = null;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Необходима авторизация" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    adminClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");
    const token = authHeader.slice("Bearer ".length);
    const { data: { user }, error: authError } = await adminClient.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Неверный токен авторизации" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    userId = user.id;

    const body = await req.json();
    const prompt = typeof body?.prompt === "string" ? body.prompt.trim() : "";
    if (!prompt) {
      return new Response(JSON.stringify({ error: "Опишите тему текста" }), {
        status: 422,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (prompt.length > PROMPT_LIMIT) {
      return new Response(JSON.stringify({ error: `Описание текста — максимум ${PROMPT_LIMIT} символов` }), {
        status: 422,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: debitRows, error: debitError } = await adminClient.rpc("debit_addon_service", {
      p_user_id: userId,
      p_service_name: "generate_lyrics",
      p_description: "Создание текста песни с AI",
      p_metadata: { request_id: requestId, service_name: "generate_lyrics" },
    });
    if (debitError) {
      const insufficient = debitError.message?.includes("Insufficient balance");
      return new Response(JSON.stringify({ error: insufficient ? "Недостаточно средств на балансе" : "Услуга временно недоступна" }), {
        status: insufficient ? 402 : 503,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const debit = debitRows?.[0];
    debitedAmount = Number(debit?.amount_debited || 0);
    const { data: logRow, error: logError } = await adminClient
      .from("generation_logs")
      .insert({
        user_id: userId,
        request_id: requestId,
        service_id: debit?.service_id || null,
        service_name: "generate_lyrics",
        provider: debit?.provider || "music_ai",
        provider_operation: debit?.provider_operation || "generate_lyrics",
        provider_model: null,
        model: "lyrics-ai",
        prompt,
        status: "pending",
        cost_rub: debitedAmount,
        sale_price_rub: debitedAmount,
        base_cost_credits: Number(debit?.base_cost_credits || 0),
        generation_params: { prompt_length: prompt.length },
      })
      .select("id")
      .single();
    if (logError || !logRow?.id) {
      console.error("Failed to create lyrics log:", logError);
      throw new Error("Не удалось зафиксировать платную операцию");
    }
    generationLogId = logRow?.id || null;

    const apiKey = Deno.env.get("SUNO_API_KEY");
    if (!apiKey) throw new Error("Музыкальный AI временно недоступен");

    const callbackUrl = `${supabaseUrl}/functions/v1/lyrics-callback`;
    const response = await fetch(`${API_BASE}/api/v1/lyrics`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ prompt, callBackUrl: callbackUrl }),
    });
    const result = await response.json();
    if (!response.ok || result.code !== 200 || !result.data?.taskId) {
      throw new Error(result.msg || "Не удалось запустить создание текста");
    }

    const lyricsResult = await pollLyricsResult(result.data.taskId, apiKey);
    if (!lyricsResult?.text) throw new Error("Превышено время ожидания текста");

    await adminClient.from("generated_lyrics").insert({
      user_id: userId,
      prompt,
      lyrics: lyricsResult.text,
      title: lyricsResult.title || null,
    });

    if (generationLogId) {
      await adminClient.from("generation_logs").update({
        status: "completed",
        duration_ms: Date.now() - startedAt,
        metadata: { task_id: result.data.taskId },
      }).eq("id", generationLogId);
    }

    return new Response(JSON.stringify({ success: true, lyrics: lyricsResult.text, title: lyricsResult.title }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Не удалось создать текст";
    console.error("generate-lyrics failed:", error);

    let refundSucceeded = false;
    if (adminClient && userId && debitedAmount > 0) {
      const { error: refundError } = await adminClient.rpc("refund_addon_service", {
        p_user_id: userId,
        p_amount: debitedAmount,
        p_description: "Возврат за неуспешное создание текста",
        p_metadata: { request_id: requestId, service_name: "generate_lyrics" },
      });
      if (refundError) console.error("Lyrics refund failed:", refundError);
      refundSucceeded = !refundError;
    }
    if (adminClient && generationLogId) {
      await adminClient.from("generation_logs").update({
        status: "failed",
        error_message: message,
        refund_rub: refundSucceeded ? debitedAmount : 0,
        duration_ms: Date.now() - startedAt,
      }).eq("id", generationLogId);
    }

    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
