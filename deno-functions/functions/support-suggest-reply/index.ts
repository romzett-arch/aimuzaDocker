/**
 * B4: AI-шаблоны ответов для тикетов поддержки
 * Генерирует предложение ответа по контексту тикета через DeepSeek
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TIMEWEB_AGENT_ACCESS_ID = "e046a9e4-43f6-47bc-a39f-8a9de8778d02";

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

    const body = await req.json();
    const { subject, messages } = body;
    if (!subject?.trim() || !Array.isArray(messages) || messages.length === 0) {
      return new Response(
        JSON.stringify({ error: "subject and messages required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "support_ai")
      .maybeSingle();

    const config = setting?.value as { suggest_replies?: boolean } | null;
    if (!config?.suggest_replies) {
      return new Response(
        JSON.stringify({ error: "suggest_replies not enabled" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      return new Response(
        JSON.stringify({ error: "TIMEWEB_AGENT_TOKEN not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const threadText = messages
      .map((m: { message: string; is_staff_reply?: boolean }) =>
        `${m.is_staff_reply ? "Поддержка" : "Пользователь"}: ${m.message}`
      )
      .join("\n\n")
      .substring(0, 2000);

    const systemPrompt = `Ты помощник службы поддержки музыкальной платформы AIMUZA.
Сгенерируй краткий профессиональный ответ на обращение пользователя.
Правила: вежливо, по делу, на русском. Без приветствий типа "Здравствуйте" в начале — только суть ответа.
Если нужна доп. информация — спроси конкретно. Максимум 3-4 предложения.`;

    const userPrompt = `Тема обращения: ${subject}\n\nПереписка:\n${threadText}\n\nПредложи ответ:`;

    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;
    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
      },
      body: JSON.stringify({
        model: "deepseek-v3",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: 0.5,
        max_tokens: 400,
      }),
    });

    if (!response.ok) {
      console.warn("[support-suggest-reply] DeepSeek error:", response.status);
      return new Response(
        JSON.stringify({ error: "AI service unavailable" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const data = await response.json();
    const reply = data.choices?.[0]?.message?.content?.trim() || "";

    return new Response(
      JSON.stringify({ reply }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[support-suggest-reply] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
