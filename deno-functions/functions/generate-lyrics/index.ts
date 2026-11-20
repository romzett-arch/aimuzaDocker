import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

import { recoverLyricsJob } from "../_shared/lyrics-results.ts";

const API_BASE = "https://api.sunoapi.org";
// Лимит описания: провайдер Suno принимает максимум 200 символов.
const PROMPT_LIMIT = 200;
const UUID = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i;
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const startedAt = Date.now();
  let requestId: string = crypto.randomUUID();
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

    const fromQueue = body.requestId !== undefined;
    if (fromQueue) {
      if (typeof body.requestId !== "string" || !UUID.test(body.requestId) ||
          !Number.isSafeInteger(body.expectedPrice) || body.expectedPrice < 1) {
        return json({ error: "Недопустимый запрос", code: "BAD_INPUT" }, 400);
      }
      requestId = body.requestId;
    }

    const apiKey = Deno.env.get("SUNO_API_KEY");
    if (!apiKey) return json({ error: "Музыкальный AI временно недоступен", code: "UNAVAILABLE" }, 503);

    const callbackToken = crypto.randomUUID();
    const { data: reserved, error: reservationError } = await adminClient.rpc("reserve_lyrics_generation", {
      p_id: requestId,
      p_user_id: user.id,
      p_prompt: prompt,
      p_callback_token: callbackToken,
      p_expected_price: fromQueue ? body.expectedPrice : null,
    });
    if (reservationError) {
      const reason = reservationError.message;
      if (reason.includes("Insufficient balance")) return json({ error: "Недостаточно средств на балансе", code: "INSUFFICIENT_FUNDS" }, 402);
      if (reason.includes("Lyrics price changed")) return json({ error: "Цена изменилась", code: "PRICE_CHANGED" }, 409);
      if (reason.includes("Lyrics request conflict")) return json({ error: "Идентификатор уже использован", code: "BAD_INPUT" }, 409);
      console.error("Lyrics reservation failed:", reservationError.code);
      return json({ error: "Услуга временно недоступна", code: "UNAVAILABLE" }, 503);
    }
    if (!reserved) return json({ pending: true, jobId: requestId }, 202);

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
    if (fromQueue) return json({ pending: true, jobId: requestId }, 202);

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
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
