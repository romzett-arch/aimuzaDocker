import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TIMEWEB_AGENT_ACCESS_ID = "e046a9e4-43f6-47bc-a39f-8a9de8778d02";

interface SeoGenerateRequest {
  entity_type: "track" | "profile" | "forum_topic" | "page";
  entity_id?: string;
  page_key?: string;
  context: {
    title?: string;
    artist?: string;
    genre?: string;
    mood?: string;
    duration?: number;
    bio?: string;
    category?: string;
    tracks_count?: number;
    genres?: string[];
    route?: string;
  };
  save_to_db?: boolean;
}

interface SeoGenerateResponse {
  title: string;
  description: string;
  og_title: string;
  og_description: string;
  keywords: string[];
  alt_text?: string;
}

type AiProvider = "deepseek" | "timeweb";

interface ChatCompletionMessage {
  content?: string | Array<{ type?: string; text?: string }>;
  role?: string;
  reasoning_content?: string;
  provider_specific_fields?: {
    reasoning_content?: string;
  };
}

interface ChatCompletionResponse {
  choices?: Array<{
    finish_reason?: string;
    index?: number;
    message?: ChatCompletionMessage;
  }>;
}

function normalizeModel(provider: AiProvider, configuredModel?: string): string {
  const rawModel = configuredModel?.trim();
  if (!rawModel) {
    return provider === "timeweb" ? "deepseek-v3" : "deepseek-chat";
  }

  if (provider === "timeweb") {
    const lowered = rawModel.toLowerCase();
    if (
      lowered === "deepseek-v3.2" ||
      lowered.includes("reasoner") ||
      lowered.includes("deepseek/deepseek-reasoner")
    ) {
      return "deepseek-v3";
    }
  }

  return rawModel;
}

function extractMessageContent(message?: ChatCompletionMessage): string {
  if (!message?.content) return "";

  if (typeof message.content === "string") {
    return message.content.trim();
  }

  return message.content
    .map((part) => (typeof part.text === "string" ? part.text : ""))
    .join("")
    .trim();
}

function extractReasoningContent(message?: ChatCompletionMessage): string {
  return (
    message?.reasoning_content?.trim() ||
    message?.provider_specific_fields?.reasoning_content?.trim() ||
    ""
  );
}

function getFallbackContent(message?: ChatCompletionMessage): string {
  const directContent = extractMessageContent(message);
  if (directContent) return directContent;

  const reasoningContent = extractReasoningContent(message);
  if (reasoningContent.includes("{")) {
    return reasoningContent;
  }

  return "";
}

function buildPrompt(
  entityType: string,
  context: SeoGenerateRequest["context"],
  systemPrompt: string,
  style: string
): string {
  const styleNote = `Стиль текста: ${style}.`;
  const routeNote = context.route ? `\n- Маршрут: ${context.route}` : "";
  let userPrompt = "";

  switch (entityType) {
    case "track":
      userPrompt = `Сгенерируй SEO-тексты для музыкального трека:
- Название: ${context.title || "Без названия"}
- Артист: ${context.artist || "Неизвестен"}
- Жанр: ${context.genre || "Не указан"}
- Настроение: ${context.mood || "Не указано"}
- Длительность: ${context.duration ? `${Math.floor(context.duration / 60)}:${String(context.duration % 60).padStart(2, "0")}` : "Не указана"}
- Интент страницы: слушать трек, открыть артиста, оценить релиз, перейти к дистрибуции`;
      break;
    case "profile":
      userPrompt = `Сгенерируй SEO-тексты для профиля артиста:
- Имя/ник: ${context.artist || "Артист"}
- Био: ${context.bio || "Не указано"}
- Жанры: ${context.genres?.join(", ") || context.genre || "Не указаны"}
- Количество треков: ${context.tracks_count ?? 0}
- Интент страницы: открыть артиста, познакомиться с релизами, подписаться на профиль`;
      break;
    case "forum_topic":
      userPrompt = `Сгенерируй SEO-тексты для темы форума:
- Заголовок: ${context.title || "Без названия"}
- Категория: ${context.category || "Общее обсуждение"}
- Интент страницы: ответить на вопрос, прочитать обсуждение сообщества, перейти к связанным темам`;
      break;
    case "page":
      userPrompt = `Сгенерируй SEO для страницы AIMUZA:
- Ключ страницы: ${context.title || "Главная"}
- Тип страницы: ${context.category || "landing"}
- Интент страницы: ${context.bio || "Главный вход в экосистему AIMUZA"}${routeNote}`;
      break;
    default:
      userPrompt = `Сгенерируй SEO-тексты для: ${JSON.stringify(context)}`;
  }

  return `${systemPrompt}
${styleNote}

${userPrompt}

Критические правила:
- AIMUZA — не просто генератор музыки. Это экосистема: AI-музыка, сообщество артистов, публикация и дистрибуция.
- Не обещай "бесплатно", "лучший", "номер 1", "гарантированный успех" и другие неподтверждённые claims.
- Не добавляй хвост вроде "| AIMUZA" в конец title, бренд добавится отдельно при рендере.
- Title должен отражать поисковый интент страницы, description — выгоду и содержание без кликбейта.
- Для community и distribution страниц не сужай смысл до одной лишь AI-генерации.

Верни ТОЛЬКО валидный JSON без markdown и пояснений:
{
  "title": "Meta Title до 70 символов",
  "description": "Meta Description до 160 символов с призывом к действию",
  "og_title": "Заголовок для соцсетей",
  "og_description": "Описание для соцсетей с эмоциями",
  "keywords": ["ключевое", "слово", "массив"],
  "alt_text": "Alt-текст для обложки (если применимо)"
}`;
}

function parseJsonFromResponse(text: string): SeoGenerateResponse | null {
  try {
    const fencedJsonMatch = text.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
    if (fencedJsonMatch?.[1]) {
      return JSON.parse(fencedJsonMatch[1].trim()) as SeoGenerateResponse;
    }

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      return JSON.parse(jsonMatch[0]) as SeoGenerateResponse;
    }
  } catch {
    // fallback
  }
  return null;
}

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const token = authHeader.replace("Bearer ", "").trim();
    if (!token) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: hasAdmin } = await supabase.rpc("has_role", { _user_id: user.id, _role: "admin" });
    const { data: hasSuperAdmin } = await supabase.rpc("has_role", { _user_id: user.id, _role: "super_admin" });
    if (!hasAdmin && !hasSuperAdmin) {
      return new Response(
        JSON.stringify({ error: "Forbidden: admin role required" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = (await req.json()) as SeoGenerateRequest;
    const { entity_type, entity_id, page_key, context, save_to_db = false } = body;

    if (!entity_type || !context) {
      return new Response(
        JSON.stringify({ error: "entity_type и context обязательны" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: keyRows, error: keyError } = await supabase
      .from("api_keys")
      .select("service_name, key_value")
      .in("service_name", ["DEEPSEEK_API_KEY", "TIMEWEB_AGENT_TOKEN"])
      .eq("is_active", true)
      .returns<{ service_name: string; key_value: string }[]>();

    if (keyError) {
      console.warn("[seo-ai-generate] api_keys fallback to env:", keyError.message);
    }

    const keyMap = (keyRows || []).reduce<Record<string, string>>((acc, row) => {
      acc[row.service_name] = row.key_value;
      return acc;
    }, {});

    const deepseekApiKey = Deno.env.get("DEEPSEEK_API_KEY")?.trim() || keyMap.DEEPSEEK_API_KEY?.trim() || "";
    const timewebToken = Deno.env.get("TIMEWEB_AGENT_TOKEN")?.trim() || keyMap.TIMEWEB_AGENT_TOKEN?.trim() || "";

    const { data: configRows } = await supabase
      .from("seo_ai_config")
      .select("config_key, config_value")
      .in("config_key", [
        "prompt_template",
        "prompt_style",
        "ai_provider",
        "ai_model",
        "ai_base_url",
        "product_profile",
        "forbidden_claims",
      ]);

    const config: Record<string, string> = {};
    (configRows || []).forEach((r) => {
      config[r.config_key] = r.config_value;
    });

    const productProfile = config.product_profile || "AIMUZA — экосистема, где AI-музыка, сообщество артистов и дистрибуция равноправны.";
    const forbiddenClaims = config.forbidden_claims || "бесплатно; номер 1; гарантированный успех; лучший без подтверждения";
    const promptTemplate = config.prompt_template || `Ты — senior SEO-редактор AIMUZA. ${productProfile} Пиши на русском, честно, конкретно и без переобещаний. Запрещённые формулировки: ${forbiddenClaims}.`;
    const promptStyle = config.prompt_style || "профессионально";
    const configuredProvider = config.ai_provider?.trim().toLowerCase();

    let provider: AiProvider | null = null;
    if (configuredProvider === "timeweb" && timewebToken) {
      provider = "timeweb";
    } else if (configuredProvider === "deepseek" && deepseekApiKey) {
      provider = "deepseek";
    } else if (timewebToken) {
      provider = "timeweb";
    } else if (deepseekApiKey) {
      provider = "deepseek";
    }

    if (!provider) {
      return new Response(
        JSON.stringify({ error: "AI не настроен. Укажите TIMEWEB_AGENT_TOKEN или DEEPSEEK_API_KEY." }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const model = normalizeModel(provider, config.ai_model);
    const baseUrl = provider === "timeweb"
      ? `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1`
      : (config.ai_base_url || "https://api.deepseek.com/v1").replace(/\/$/, "");
    const apiKey = provider === "timeweb" ? timewebToken : deepseekApiKey;

    const fullPrompt = buildPrompt(entity_type, context, promptTemplate, promptStyle);
    const chatUrl = `${baseUrl}/chat/completions`;
    const buildChatBody = (selectedModel: string, systemContent: string, temperature: number, maxTokens: number) =>
      JSON.stringify({
        model: selectedModel,
        messages: [
          { role: "system", content: systemContent },
          { role: "user", content: fullPrompt },
        ],
        temperature,
        max_tokens: maxTokens,
      });

    const chatRes = await fetch(chatUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: buildChatBody(
        model,
        "Ты возвращаешь только валидный JSON. Никакого текста до или после.",
        0.2,
        2200,
      ),
    });

    if (!chatRes.ok) {
      const errText = await chatRes.text();
      console.error("[seo-ai-generate] API error:", provider, chatRes.status, errText);
      return new Response(
        JSON.stringify({
          error: `Ошибка ${provider === "timeweb" ? "Timeweb Agent" : "DeepSeek"} API (${chatRes.status}): ${errText.slice(0, 200)}`,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let chatData = (await chatRes.json()) as ChatCompletionResponse;
    let content = getFallbackContent(chatData?.choices?.[0]?.message);

    if (!content) {
      const reasoning = extractReasoningContent(chatData?.choices?.[0]?.message);
      console.warn("[seo-ai-generate] Empty AI content, retrying with stricter prompt", {
        provider,
        model,
        finishReason: chatData?.choices?.[0]?.finish_reason,
        hasReasoning: Boolean(reasoning),
      });

      const retryModel = provider === "timeweb" ? "deepseek-v3" : model;
      const retryRes = await fetch(chatUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: buildChatBody(
          retryModel,
          "Без рассуждений. Сразу верни только валидный JSON-объект без markdown и пояснений.",
          0,
          3200,
        ),
      });

      if (retryRes.ok) {
        chatData = (await retryRes.json()) as ChatCompletionResponse;
        content = getFallbackContent(chatData?.choices?.[0]?.message);
      } else {
        const retryErrText = await retryRes.text();
        console.error("[seo-ai-generate] Retry API error:", provider, retryRes.status, retryErrText);
      }
    }

    const result = parseJsonFromResponse(content);

    if (!result || !result.title || !result.description) {
      console.error("[seo-ai-generate] Invalid AI JSON:", content.slice(0, 500));
      return new Response(
        JSON.stringify({ error: "AI не вернул валидный JSON. Попробуйте ещё раз." }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (save_to_db && (entity_id || page_key)) {
      const token = authHeader.replace("Bearer ", "");
      let updatedBy: string | null = null;
      if (token) {
        const { data: { user: currentUser } } = await supabase.auth.getUser(token);
        updatedBy = currentUser?.id ?? null;
      }

      const row = {
        entity_type,
        entity_id: entity_id || null,
        page_key: page_key || null,
        title: result.title.slice(0, 255),
        description: result.description.slice(0, 500),
        og_title: result.og_title?.slice(0, 255) || result.title,
        og_description: result.og_description?.slice(0, 500) || result.description,
        keywords: result.keywords || [],
        ai_generated: true,
        ai_generated_at: new Date().toISOString(),
        ai_model: model,
        updated_at: new Date().toISOString(),
        updated_by: updatedBy,
      };

      let existing: { id: string } | null = null;
      if (entity_id) {
        const { data } = await supabase
          .from("seo_metadata")
          .select("id")
          .eq("entity_type", entity_type)
          .eq("entity_id", entity_id)
          .maybeSingle();
        existing = data;
      } else if (page_key) {
        const { data } = await supabase
          .from("seo_metadata")
          .select("id")
          .eq("entity_type", entity_type)
          .eq("page_key", page_key)
          .maybeSingle();
        existing = data;
      }

      if (existing) {
        await supabase.from("seo_metadata").update(row).eq("id", existing.id);
      } else {
        await supabase.from("seo_metadata").insert(row);
      }
    }

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("[seo-ai-generate] Error:", error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
