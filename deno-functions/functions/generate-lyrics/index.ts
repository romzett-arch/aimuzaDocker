import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

import { recoverLyricsJob } from "../_shared/lyrics-results.ts";

const API_BASE = "https://api.sunoapi.org";
const PROMPT_LIMIT = 200;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const startedAt = Date.now();
  const requestId = crypto.randomUUID();
  let userId: string | null = null;
  let debitedAmount = 0;
  let generationLogId: string | null = null;
  let jobCreated = false;
  let dispatched = false;
  let adminClient: SupabaseClient<any> | null = null;

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

    const callbackToken = crypto.randomUUID();
    const { error: jobError } = await adminClient.from("lyrics_generation_jobs").insert({
      id: requestId, user_id: userId, prompt, callback_token: callbackToken, generation_log_id: generationLogId,
    });
    if (jobError) throw jobError;
    jobCreated = true;
    const callbackBase = new URL(Deno.env.get("LYRICS_CALLBACK_URL") || "/functions/v1/lyrics-callback", Deno.env.get("SUNO_CALLBACK_URL") || "https://aimuza.ru");
    callbackBase.search = "";
    callbackBase.searchParams.set("job", requestId);
    callbackBase.searchParams.set("token", callbackToken);
    const callbackUrl = callbackBase.toString();
    // Once dispatch begins a transport error is ambiguous. Keep the durable job:
    // the authenticated callback can still deliver the result after a disconnect.
    dispatched = true;
    const response = await fetch(`${API_BASE}/api/v1/lyrics`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ prompt, callBackUrl: callbackUrl }),
      signal: AbortSignal.timeout(20000),
    });
    const result = await response.json().catch(() => ({})) as Record<string, unknown>;
    const resultData = result.data as Record<string, unknown> | undefined;
    const taskId = resultData?.taskId ?? resultData?.task_id;
    if (!response.ok || result.code !== 200 || typeof taskId !== "string" || !taskId) {
      dispatched = false;
      throw new Error(typeof result.msg === "string" ? result.msg : "Не удалось запустить создание текста");
    }

    const { error: taskError } = await adminClient.from("lyrics_generation_jobs")
      .update({ provider_task_id: taskId }).eq("id", requestId);
    if (taskError) throw taskError;

    for (let attempt = 0; attempt < 20 && Date.now() - startedAt < 40000; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 2000));
      try {
        const saved = await recoverLyricsJob(adminClient, { id: requestId, provider_task_id: taskId }, apiKey);
        if (saved.length) return new Response(JSON.stringify({ success: true, id: saved[0].id, lyrics: saved[0].lyrics, title: saved[0].title, saved: true }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      } catch (pollError) {
        const { data: jobState } = await adminClient.from("lyrics_generation_jobs").select("status,error_message").eq("id", requestId).maybeSingle();
        if (jobState?.status === 'failed') return new Response(JSON.stringify({ error: jobState.error_message || 'Не удалось создать текст' }), {
          status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
        console.error("Lyrics polling will be retried by recovery worker", pollError);
        break;
      }
    }
    return new Response(JSON.stringify({ pending: true, jobId: requestId, message: 'Текст создаётся и появится в «Мои тексты» автоматически' }), {
      status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Не удалось создать текст";
    console.error("generate-lyrics failed:", error);

    if (dispatched) {
      return new Response(JSON.stringify({ pending: true, jobId: requestId, message: 'Результат будет сохранён в «Мои тексты» автоматически' }), {
        status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (jobCreated && adminClient) {
      const { error: failError } = await adminClient.rpc("fail_lyrics_job", { p_job_id: requestId, p_error: message });
      if (failError) console.error("Lyrics failure settlement needs recovery", failError);
      return new Response(JSON.stringify({ error: message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
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
