/**
 * B7: AI-проверка метаданных для дистрибуции
 * Валидация по требованиям Spotify, Apple Music и др. стриминговых площадок
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

    const body = await req.json().catch(() => ({}));
    const {
      title,
      performerName,
      musicAuthor,
      lyricsAuthor,
      hasLyrics,
      isOriginalWork,
      hasSamples,
      samplesLicensed,
      hasInterpolations,
      interpolationsLicensed,
    } = body;

    if (!title?.trim() || !performerName?.trim() || !musicAuthor?.trim()) {
      return new Response(
        JSON.stringify({ error: "title, performerName, musicAuthor required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "distribution_check")
      .maybeSingle();

    const config = setting?.value as { enabled?: boolean } | null;
    if (!config?.enabled) {
      return new Response(
        JSON.stringify({ error: "distribution_check not enabled" }),
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

    const systemPrompt = `Ты эксперт по метаданным для дистрибуции музыки (Spotify, Apple Music, VK Музыка).
Проверь метаданные на соответствие требованиям стриминговых площадок.

Ответь СТРОГО в формате JSON:
{
  "ok": true/false,
  "errors": ["критичные ошибки, блокирующие дистрибуцию"],
  "warnings": ["предупреждения, лучше исправить"],
  "suggestions": ["рекомендации по улучшению"]
}

Правила:
- Имя исполнителя: без ролей, дат, инструментов, SEO-слов. Только имя.
- Название трека: без "Official", "Exclusive", URL, соцсетей. Версии в скобках: "Title (Version)".
- Авторы: полные имена, консистентное написание.
- hasLyrics=true но lyricsAuthor пустой — ошибка.
- hasSamples=true но samplesLicensed=false — ошибка.
- hasInterpolations=true но interpolationsLicensed=false — ошибка.
- Пустые или слишком короткие поля — ошибка.
- Слишком длинные имена (>100 символов) — предупреждение.`;

    const userPrompt = `Метаданные:
- Название: ${title}
- Исполнитель: ${performerName}
- Автор музыки: ${musicAuthor}
- Автор текста: ${hasLyrics ? (lyricsAuthor || "(не указан)") : "— (инструментал)"}
- Оригинал: ${isOriginalWork}
- Сэмплы: ${hasSamples} (лицензированы: ${samplesLicensed})
- Интерполяции: ${hasInterpolations} (лицензированы: ${interpolationsLicensed})

Проверь и верни JSON:`;

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
        max_tokens: 400,
      }),
    });

    if (!response.ok) {
      console.warn("[distribution-check] DeepSeek error:", response.status);
      return new Response(
        JSON.stringify({ error: "AI service unavailable" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const data = await response.json();
    const text = data.choices?.[0]?.message?.content?.trim();
    if (!text) {
      return new Response(
        JSON.stringify({ ok: true, errors: [], warnings: [], suggestions: [] }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    let result = { ok: true, errors: [] as string[], warnings: [] as string[], suggestions: [] as string[] };
    if (jsonMatch) {
      try {
        const parsed = JSON.parse(jsonMatch[0]);
        result = {
          ok: parsed.ok !== false && (!parsed.errors || parsed.errors.length === 0),
          errors: Array.isArray(parsed.errors) ? parsed.errors : [],
          warnings: Array.isArray(parsed.warnings) ? parsed.warnings : [],
          suggestions: Array.isArray(parsed.suggestions) ? parsed.suggestions : [],
        };
      } catch {
        result.ok = true;
      }
    }

    return new Response(
      JSON.stringify(result),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[distribution-check] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
