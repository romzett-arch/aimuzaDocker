import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const AGENT_ACCESS_ID = "0846d064-4950-4d79-a54c-62ba315cdb34";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Необходима авторизация" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await (supabase.auth as any).getClaims?.(token) ?? { data: null, error: new Error("getClaims not available") };
    if (claimsError || !claimsData?.claims?.sub) {
      return new Response(
        JSON.stringify({ error: "Неверный токен" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const user_id = claimsData.claims.sub as string;
    const body = await req.json() as { mode: "description" | "tags"; title: string; lyrics?: string; genreName?: string; description?: string };

    const { mode, title, lyrics = "", genreName = "", description = "" } = body;

    if (!title?.trim()) {
      return new Response(
        JSON.stringify({ error: "Укажите название трека" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const serviceName = mode === "description" ? "track_description" : "track_auto_tags";
    const { data: service } = await supabase
      .from("addon_services")
      .select("price_rub")
      .eq("name", serviceName)
      .maybeSingle();

    const price = service?.price_rub ?? (mode === "description" ? 3 : 0);

    if (price > 0) {
      const { data: profile } = await supabase.from("profiles").select("balance").eq("user_id", user_id).maybeSingle();
      if (!profile || (profile.balance || 0) < price) {
        return new Response(
          JSON.stringify({ error: "Недостаточно средств на балансе" }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const newBalance = (profile.balance || 0) - price;
      const { error: balErr } = await supabase.from("profiles").update({ balance: newBalance }).eq("user_id", user_id);
      if (balErr) throw new Error("Ошибка списания");

      await supabase.from("balance_transactions").insert({
        user_id,
        amount: -price,
        balance_after: newBalance,
        type: "addon_service",
        description: mode === "description" ? "AI-описание трека" : "AI-теги трека",
        metadata: { service: serviceName },
      });
    }

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) throw new Error("TIMEWEB_AGENT_TOKEN not configured");

    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${AGENT_ACCESS_ID}/v1/chat/completions`;

    if (mode === "description") {
      const systemPrompt = `Ты эксперт по описанию музыкальных треков. Создай краткое SEO-описание (2-4 предложения) для трека на основе названия, текста и жанра.
Правила: опиши настроение, тему, стиль; пиши на русском; без хештегов; максимум 200 символов.`;
      const userPrompt = `Название: ${title}\n${genreName ? `Жанр: ${genreName}\n` : ""}${lyrics ? `Текст (первые 500 символов):\n${lyrics.substring(0, 500)}` : ""}`;

      const res = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
        body: JSON.stringify({
          model: "deepseek-v3.2",
          messages: [{ role: "system", content: systemPrompt }, { role: "user", content: userPrompt }],
          temperature: 0.5,
          max_tokens: 300,
        }),
      });

      if (!res.ok) throw new Error("AI API error");
      const data = await res.json();
      const description = data.choices?.[0]?.message?.content?.trim() || "";
      return new Response(JSON.stringify({ description }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // mode === "tags"
    const systemPrompt = `Ты эксперт по SEO-тегам для музыки. Подбери 5-10 ключевых тегов для поиска (на русском, через запятую).
Учитывай: жанр, настроение, тему, инструменты, стиль. Теги — отдельные слова или короткие фразы.`;
    const userPrompt = `Название: ${title}\n${genreName ? `Жанр: ${genreName}\n` : ""}${description ? `Описание: ${description.substring(0, 300)}\n` : ""}${lyrics ? `Текст:\n${lyrics.substring(0, 400)}` : ""}`;

    const res = await fetch(apiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
      body: JSON.stringify({
        model: "deepseek-v3.2",
        messages: [{ role: "system", content: systemPrompt }, { role: "user", content: userPrompt }],
        temperature: 0.3,
        max_tokens: 150,
      }),
    });

    if (!res.ok) throw new Error("AI API error");
    const data = await res.json();
    const tagsText = data.choices?.[0]?.message?.content?.trim() || "";
    const tags = tagsText.split(/[,،،、;]/).map((t: string) => t.trim()).filter(Boolean).slice(0, 10);
    return new Response(JSON.stringify({ tags }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err) {
    console.error("[track-metadata]", err);
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : "Ошибка сервера" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
