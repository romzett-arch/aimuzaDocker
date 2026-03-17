/**
 * B5: AI-дайджест для админки
 * Суммаризация метрик платформы через DeepSeek
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
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

    const { data: adminCheck } = await supabase.rpc("is_admin" as any, { _user_id: user.id });
    if (!adminCheck) {
      return new Response(
        JSON.stringify({ error: "Admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "admin_digest")
      .maybeSingle();

    const config = setting?.value as { enabled?: boolean } | null;
    if (!config?.enabled) {
      return new Response(
        JSON.stringify({ error: "admin_digest not enabled" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json().catch(() => ({}));
    const { economy, moderation, distribution, support } = body;

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      return new Response(
        JSON.stringify({ error: "TIMEWEB_AGENT_TOKEN not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const metricsText = [
      economy && `Экономика: пользователи ${economy.users?.total || 0}, активных авторов ${economy.users?.active_creators || 0}, платных ${economy.users?.paying || 0}. Треков сегодня: ${economy.content?.tracks_today || 0}, качество ${(economy.content?.avg_quality || 0).toFixed(1)}/10. В обращении ₽${(economy.currency?.total_in_circulation || 0).toLocaleString()}`,
      moderation && `Модерация: ожидают ${moderation.pending || 0}, на голосовании ${moderation.voting || 0}, одобрено ${moderation.approved || 0}, отклонено ${moderation.rejected || 0}`,
      distribution && `Дистрибуция: в очереди ${distribution.pending || 0}, одобрено ${distribution.approved || 0}, распространено ${distribution.distributed || 0}`,
      support && `Поддержка: открытых ${support.open || 0}, в работе ${support.in_progress || 0}, ожидают ответа ${support.waiting_response || 0}`,
    ]
      .filter(Boolean)
      .join("\n");

    const systemPrompt = `Ты аналитик платформы AIMUZA. Дай краткий дайджест (3-5 предложений) на русском: ключевые метрики, что требует внимания, рекомендации. Без вступлений.`;

    const userPrompt = `Метрики на ${new Date().toLocaleDateString("ru-RU")}:\n\n${metricsText || "Данные не переданы"}\n\nДай дайджест:`;

    const agentId = Deno.env.get("TIMEWEB_AGENT_ID") || "";
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${agentId}/v1/chat/completions`;
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
        temperature: 0.3,
        max_tokens: 500,
      }),
    });

    if (!response.ok) {
      console.warn("[admin-digest] DeepSeek error:", response.status);
      return new Response(
        JSON.stringify({ error: "AI service unavailable" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const data = await response.json();
    const digest = data.choices?.[0]?.message?.content?.trim() || "";

    return new Response(
      JSON.stringify({ digest }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[admin-digest] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
