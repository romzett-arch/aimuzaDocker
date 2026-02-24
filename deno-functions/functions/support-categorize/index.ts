/**
 * B3: AI-категоризация тикетов поддержки
 * Определяет category и priority по subject + message через DeepSeek
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TIMEWEB_AGENT_ACCESS_ID = "0846d064-4950-4d79-a54c-62ba315cdb34";

const VALID_CATEGORIES = ["bug", "feature", "payment", "account", "generation", "other"];
const VALID_PRIORITIES = ["low", "medium", "high", "urgent"];

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
    const { subject, message } = body;
    if (!subject?.trim() || !message?.trim()) {
      return new Response(
        JSON.stringify({ error: "subject and message required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "support_ai")
      .maybeSingle();

    const config = setting?.value as { auto_categorize?: boolean; auto_priority?: boolean } | null;
    if (!config?.auto_categorize && !config?.auto_priority) {
      return new Response(
        JSON.stringify({ error: "support_ai not enabled" }),
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

    const systemPrompt = `Ты помощник категоризации тикетов поддержки музыкальной платформы.
Ответь СТРОГО в формате JSON: {"category": "...", "priority": "..."}

category — одна из: bug, feature, payment, account, generation, other
- bug: ошибки, баги, сбои
- feature: предложения, идеи, улучшения
- payment: оплата, баланс, подписка
- account: аккаунт, вход, настройки профиля
- generation: генерация музыки, Suno, промпты
- other: всё остальное

priority — одна из: low, medium, high, urgent
- low: общие вопросы, предложения
- medium: типичные проблемы
- high: блокирующие проблемы, потеря данных
- urgent: критичные сбои, безопасность`;

    const userPrompt = `Тема: ${subject}\n\nСообщение: ${message.substring(0, 800)}`;

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
        temperature: 0.1,
        max_tokens: 100,
      }),
    });

    if (!response.ok) {
      console.warn("[support-categorize] DeepSeek error:", response.status);
      return new Response(
        JSON.stringify({ error: "AI service unavailable" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const data = await response.json();
    const text = data.choices?.[0]?.message?.content?.trim();
    if (!text) {
      return new Response(
        JSON.stringify({ category: "other", priority: "medium" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    const parsed = jsonMatch ? JSON.parse(jsonMatch[0]) : {};
    const category = VALID_CATEGORIES.includes(parsed.category) ? parsed.category : "other";
    const priority = VALID_PRIORITIES.includes(parsed.priority) ? parsed.priority : "medium";

    return new Response(
      JSON.stringify({ category, priority }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[support-categorize] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
