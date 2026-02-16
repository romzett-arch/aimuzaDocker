import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

type Mode =
  | "spell_check"
  | "expand_topic"
  | "expand_to_topic"
  | "expand_reply"
  | "improve_text"
  | "summarize_thread"
  | "suggest_arguments"
  | "auto_tags";

const AGENT_ACCESS_ID = "e046a9e4-43f6-47bc-a39f-8a9de8778d02";

const SERVICE_NAMES: Record<Mode, string> = {
  spell_check: "forum_spell_check",
  expand_topic: "forum_expand_topic",
  expand_to_topic: "forum_expand_topic",
  expand_reply: "forum_expand_reply",
  improve_text: "forum_improve_text",
  summarize_thread: "forum_summarize_thread",
  suggest_arguments: "forum_suggest_arguments",
  auto_tags: "forum_auto_tags",
};

const DEFAULT_PRICES: Record<Mode, number> = {
  spell_check: 3,
  expand_topic: 5,
  expand_to_topic: 5,
  expand_reply: 5,
  improve_text: 4,
  summarize_thread: 3,
  suggest_arguments: 4,
  auto_tags: 0, // Free for SEO
};

const MESSAGES: Record<Mode, string> = {
  spell_check: "Текст проверен!",
  expand_topic: "Тезисы развёрнуты!",
  expand_to_topic: "Тема сгенерирована!",
  expand_reply: "Ответ развёрнут!",
  improve_text: "Текст улучшен!",
  summarize_thread: "Резюме готово!",
  suggest_arguments: "Аргументы готовы!",
  auto_tags: "Теги сгенерированы!",
};

const TAG_COLORS = [
  "#6366f1", "#10b981", "#f59e0b", "#ec4899", "#ef4444",
  "#8b5cf6", "#06b6d4", "#a855f7", "#14b8a6", "#f97316",
  "#84cc16", "#0ea5e9", "#d946ef", "#22c55e", "#e11d48",
  "#7c3aed", "#0891b2", "#c026d3", "#16a34a", "#ea580c",
];

function buildPrompts(
  mode: Mode,
  text: string | undefined,
  topicTitle: string | undefined,
  topicContent: string | undefined,
  threadPosts: string | undefined,
): { systemPrompt: string; userPrompt: string } {
  const topicContext = topicTitle ? `Тема обсуждения: "${topicTitle}"` : "";
  const contentContext = topicContent
    ? `\nКонтекст темы: ${topicContent.replace(/<[^>]*>/g, "").slice(0, 500)}`
    : "";

  switch (mode) {
    case "spell_check":
      return {
        systemPrompt: `Ты профессиональный корректор текста. Твоя задача — исправить орфографические, грамматические и пунктуационные ошибки в тексте.

Правила:
- Исправь все орфографические ошибки
- Исправь грамматические ошибки
- Расставь правильную пунктуацию
- Сохрани оригинальное форматирование (переносы строк, абзацы)
- Сохрани стиль и тон автора
- НЕ меняй смысл текста
- НЕ переписывай предложения, если они грамматически верны
- НЕ добавляй и НЕ удаляй контент
- Если текст написан без ошибок — верни его как есть
- Отвечай ТОЛЬКО исправленным текстом, без пояснений и комментариев`,
        userPrompt: `Проверь и исправь ошибки в этом тексте:\n\n${text}`,
      };

    case "expand_to_topic":
      return {
        systemPrompt: `Ты опытный участник музыкального форума. Пользователь даёт тебе набор тезисов — ты должен:
1. Придумать короткий, цепляющий заголовок для темы (до 100 символов)
2. Развернуть тезисы в полноценный структурированный пост
3. Подобрать до 3 наиболее подходящих тегов из списка

Доступные теги (выбирай ТОЛЬКО из этого списка, используй точные значения name):
discussion, tutorial, question, showcase, bug-report, feature-request, tip, ai-generation, mixing, lyrics, beats, collab

Формат ответа — строго JSON:
{"title": "заголовок темы", "content": "текст поста", "tags": ["tag1", "tag2"]}

Правила для контента:
- Развей каждый тезис в полноценный абзац
- Используй разговорный, но грамотный стиль общения на форуме
- Сохрани все идеи и мысли автора
- Добавь уместные вопросы к сообществу
- НЕ используй канцелярит и шаблонные фразы
- Пиши живо и естественно
- Длина: 3-6 абзацев
- Разделяй абзацы двойным переносом строки

Правила для заголовка:
- Краткий, интригующий, без кликбейта
- На русском языке

Правила для тегов:
- Выбирай от 1 до 3 тегов, максимально релевантных содержанию
- Используй ТОЛЬКО имена из предоставленного списка

Отвечай ТОЛЬКО валидным JSON, без markdown-обёрток.`,
        userPrompt: `Развей эти тезисы в полноценную тему для форума:\n\n${text}`,
      };

    case "expand_reply":
      return {
        systemPrompt: `Ты опытный участник музыкального форума. Развей краткие тезисы в полноценный ответ на тему.

Правила:
- Развей каждый тезис в полноценный абзац
- Добавь логические связки между идеями
- Используй разговорный, но грамотный стиль общения на форуме
- Сохрани все идеи и мысли автора
- Добавь уместные вопросы и реакции на тему обсуждения
- НЕ используй канцелярит и шаблонные фразы
- НЕ добавляй заголовки — только текст ответа
- Пиши живо и естественно, как реальный человек
- Длина: 2-5 абзацев
- Отвечай ТОЛЬКО текстом ответа, без пояснений`,
        userPrompt: `${topicContext}${contentContext}\n\nРазвей эти тезисы в полноценный ответ:\n\n${text}`,
      };

    case "improve_text":
      return {
        systemPrompt: `Ты литературный редактор. Улучши текст поста на форуме.

Правила:
- Улучши стиль и читаемость
- Исправь орфографию и пунктуацию
- Сделай текст более структурированным
- Сохрани ВСЕ оригинальные мысли и смысл
- НЕ добавляй новые идеи от себя
- НЕ сокращай текст существенно
- Сохрани тон автора (если неформальный — оставь неформальным)
- НЕ используй канцелярит
- Отвечай ТОЛЬКО улучшенным текстом, без пояснений`,
        userPrompt: `Улучши этот текст:\n\n${text}`,
      };

    case "summarize_thread":
      return {
        systemPrompt: `Ты аналитик форумных дискуссий. Создай краткое, информативное резюме обсуждения в теме.

Правила:
- Выдели основные точки зрения и аргументы
- Укажи ключевые идеи каждой стороны дискуссии
- Если есть консенсус — отметь это
- Если есть разногласия — обозначь позиции
- Формат: 3-5 пунктов, коротко и по делу
- Используй маркированный список
- Добавь одно предложение в конце: «Что ещё не обсудили / какие вопросы остались»
- Отвечай ТОЛЬКО резюме, без вступлений и пояснений`,
        userPrompt: `${topicContext}${contentContext}\n\nПосты в дискуссии:\n${threadPosts || "(постов пока нет)"}`,
      };

    case "suggest_arguments":
      return {
        systemPrompt: `Ты помощник для написания ответов на музыкальном форуме. Проанализируй тему и предложи аргументы/идеи для ответа.

Правила:
- Предложи 3-5 чётких тезисов для ответа
- Учитывай контекст темы и уже написанные ответы
- Каждый тезис — 1-2 предложения
- Предлагай разные углы зрения
- Учитывай специфику музыкального сообщества
- Формат: нумерованный список
- Отвечай ТОЛЬКО списком тезисов, без вступлений`,
        userPrompt: `${topicContext}${contentContext}\n\nУже написанные ответы:\n${threadPosts || "(ответов пока нет)"}\n\nПредложи идеи для ответа.`,
      };

    case "auto_tags":
      return {
        systemPrompt: `Ты SEO-специалист музыкального форума. Твоя задача — извлечь из заголовка и текста темы КОНКРЕТНЫЕ ключевые слова, которые точно описывают содержание ИМЕННО ЭТОЙ темы.

КРИТИЧЕСКИ ВАЖНО — РЕЛЕВАНТНОСТЬ:
- Каждый тег ОБЯЗАН напрямую соответствовать тому, о чём написано в заголовке и тексте
- Если тема про горячие клавиши — теги должны быть про горячие клавиши, советы, лайфхаки
- Если тема про сведение вокала — теги должны быть про сведение, вокал, микширование  
- НИКОГДА не добавляй теги про сведение, биты, тексты, коллаб, если тема НЕ об этом
- НЕ генерируй шаблонные музыкальные теги, которые не связаны с конкретным текстом
- Перечитай заголовок ещё раз перед ответом и убедись, что КАЖДЫЙ тег описывает содержание

Правила:
- Сгенерируй от 2 до 4 тегов (лучше меньше, но точнее)
- Каждый тег: 1-3 слова на русском
- Slug: латиницей, через дефис, lowercase, транслитерация русского названия
- Не используй слишком общие теги: "музыка", "форум", "обсуждение", "вопрос"
- Теги должны быть полезны для SEO-кластеризации: пользователь, ищущий эту тему в Google, мог бы найти её по этим тегам

Формат ответа — строго JSON массив:
[{"slug": "goryachie-klavishi", "name_ru": "Горячие клавиши"}, {"slug": "sovety-novichkam", "name_ru": "Советы новичкам"}]

Отвечай ТОЛЬКО валидным JSON массивом, без markdown-обёрток и пояснений.`,
        userPrompt: `Заголовок темы: "${topicTitle || ""}"\n\nТекст темы:\n${text || topicContent || "(текст отсутствует)"}`,
      };

    default:
      // expand_topic (legacy)
      return {
        systemPrompt: `Ты опытный участник музыкального форума. Развей краткие тезисы в полноценный пост.

Правила:
- Развей каждый тезис в полноценный абзац
- Добавь логические связки
- Используй разговорный, но грамотный стиль
- Сохрани все идеи автора
- НЕ добавляй заголовки и разметку — только текст
- Длина: 3-6 абзацев
- Отвечай ТОЛЬКО текстом поста, без пояснений`,
        userPrompt: `${topicContext}${contentContext}\n\nРазвей эти тезисы в полноценный пост:\n\n${text}`,
      };
  }
}

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
    const { data, error: authError } = await supabase.auth.getClaims(token);

    if (authError || !data?.claims?.sub) {
      console.error("Auth error:", authError);
      return new Response(
        JSON.stringify({ error: "Неверный токен авторизации" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const user_id = data.claims.sub as string;
    const { mode, text, topicTitle, topicContent, threadPosts, topicId } = await req.json() as {
      mode: Mode;
      text?: string;
      topicTitle?: string;
      topicContent?: string;
      threadPosts?: string;
      topicId?: string;
    };

    console.log(`[forum-ai-helper] mode=${mode}, user=${user_id}, textLen=${text?.length || 0}`);

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      throw new Error("TIMEWEB_AGENT_TOKEN not configured");
    }

    // Get service price from addon_services
    const serviceName = SERVICE_NAMES[mode];
    if (!serviceName) {
      return new Response(
        JSON.stringify({ error: `Неизвестный режим: ${mode}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: service } = await supabase
      .from("addon_services")
      .select("price_rub, is_active")
      .eq("name", serviceName)
      .maybeSingle();

    if (service && !service.is_active) {
      return new Response(
        JSON.stringify({ error: "Эта функция временно отключена" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const price = service?.price_rub ?? DEFAULT_PRICES[mode];
    const isFreeMode = price === 0;

    let profile: { balance: number } | null = null;
    let newBalance = 0;

    if (!isFreeMode) {
      // Check balance
      const { data: profileData } = await supabase
        .from("profiles")
        .select("balance")
        .eq("user_id", user_id)
        .maybeSingle();
      profile = profileData;

      if (!profile || (profile.balance || 0) < price) {
        return new Response(
          JSON.stringify({ error: "Недостаточно средств на балансе", required: price, balance: profile?.balance || 0 }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Deduct balance
      newBalance = (profile.balance || 0) - price;
      const { error: balanceError } = await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", user_id);

      if (balanceError) {
        throw new Error("Ошибка списания баланса");
      }

      // Log transaction
      await supabase.from("balance_transactions").insert({
        user_id: user_id,
        amount: -price,
        balance_after: newBalance,
        type: "forum_ai",
        description: `Форум AI: ${MESSAGES[mode] || mode}`,
        metadata: { mode, topicTitle },
      });
    }

    const { systemPrompt, userPrompt } = buildPrompts(mode, text, topicTitle, topicContent, threadPosts);

    // Call Timeweb Agent API
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${AGENT_ACCESS_ID}/v1/chat/completions`;

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
        "x-proxy-source": "lovable-app",
      },
      body: JSON.stringify({
        model: "deepseek-v3.2",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: mode === "spell_check" || mode === "auto_tags" ? 0.1 : 0.7,
      }),
    });

    console.log(`[forum-ai-helper] Timeweb response status: ${response.status}`);

    if (!response.ok) {
      // Refund on API error (only if paid)
      if (!isFreeMode && profile) {
        await supabase
          .from("profiles")
          .update({ balance: profile.balance })
          .eq("user_id", user_id);
      }

      const errorText = await response.text();
      console.error("[forum-ai-helper] Timeweb API error:", response.status, errorText);
      throw new Error("Ошибка API — попробуйте позже");
    }

    const result = await response.json();
    const generatedContent = result.choices?.[0]?.message?.content;

    if (!generatedContent) {
      if (!isFreeMode && profile) {
        await supabase
          .from("profiles")
          .update({ balance: profile.balance })
          .eq("user_id", user_id);
      }
      throw new Error("Не удалось обработать текст");
    }

    // ── auto_tags: parse, create tags, link to topic ──
    if (mode === "auto_tags") {
      try {
        let cleanJson = generatedContent.trim();
        // Remove markdown fences
        cleanJson = cleanJson.replace(/```json\s*/gi, "").replace(/```\s*/g, "").trim();
        // Find JSON array boundaries
        const arrStart = cleanJson.indexOf("[");
        const arrEnd = cleanJson.lastIndexOf("]");
        if (arrStart !== -1 && arrEnd !== -1) {
          cleanJson = cleanJson.substring(arrStart, arrEnd + 1);
        }
        // Fix common issues
        cleanJson = cleanJson
          .replace(/,\s*]/g, "]")
          .replace(/[\x00-\x1F\x7F]/g, "");

        const tags: { slug: string; name_ru: string }[] = JSON.parse(cleanJson);
        console.log(`[forum-ai-helper] auto_tags parsed ${tags.length} tags:`, tags);

        if (!Array.isArray(tags) || tags.length === 0) {
          return new Response(
            JSON.stringify({ success: true, tags: [], mode, message: "Нет подходящих тегов" }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        const createdTagIds: string[] = [];
        const createdTags: { id: string; name: string; name_ru: string; color: string }[] = [];

        for (const tag of tags.slice(0, 5)) {
          if (!tag.slug || !tag.name_ru) continue;

          const slug = tag.slug.toLowerCase().replace(/[^a-z0-9-]/g, "").slice(0, 50);
          const nameRu = tag.name_ru.trim().slice(0, 50);
          if (!slug || !nameRu) continue;

          // Check if tag exists by slug
          const { data: existing } = await supabase
            .from("forum_tags")
            .select("id, name, name_ru, color")
            .eq("name", slug)
            .maybeSingle();

          if (existing) {
            createdTagIds.push(existing.id);
            createdTags.push(existing);
            // Increment usage_count
            await supabase
              .from("forum_tags")
              .update({ usage_count: (existing as any).usage_count ? (existing as any).usage_count + 1 : 1 })
              .eq("id", existing.id);
          } else {
            const color = TAG_COLORS[Math.floor(Math.random() * TAG_COLORS.length)];
            const { data: newTag, error: tagError } = await supabase
              .from("forum_tags")
              .insert({ name: slug, name_ru: nameRu, color, usage_count: 1 })
              .select("id, name, name_ru, color")
              .single();

            if (tagError) {
              console.error(`[forum-ai-helper] Error creating tag "${slug}":`, tagError);
              continue;
            }
            createdTagIds.push(newTag.id);
            createdTags.push(newTag);
          }
        }

        // Link tags to topic
        if (topicId && createdTagIds.length > 0) {
          // Get existing tags for this topic
          const { data: existingLinks } = await supabase
            .from("forum_topic_tags")
            .select("tag_id")
            .eq("topic_id", topicId);

          const existingTagIds = new Set((existingLinks || []).map((l: any) => l.tag_id));
          const newLinks = createdTagIds
            .filter(id => !existingTagIds.has(id))
            .slice(0, 5 - existingTagIds.size) // max 5 total tags per topic
            .map(tag_id => ({ topic_id: topicId, tag_id }));

          if (newLinks.length > 0) {
            const { error: linkError } = await supabase
              .from("forum_topic_tags")
              .insert(newLinks);
            if (linkError) {
              console.error("[forum-ai-helper] Error linking tags:", linkError);
            }
          }
          console.log(`[forum-ai-helper] Linked ${newLinks.length} auto-tags to topic ${topicId}`);
        }

        return new Response(
          JSON.stringify({
            success: true,
            tags: createdTags,
            mode,
            message: MESSAGES[mode],
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch (parseErr) {
        console.error("[forum-ai-helper] auto_tags parse error:", parseErr, "raw:", generatedContent);
        return new Response(
          JSON.stringify({ success: true, tags: [], mode, message: "Не удалось распознать теги" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    // For expand_to_topic, parse JSON to extract title + content
    if (mode === "expand_to_topic") {
      try {
        let cleanJson = generatedContent.trim();
        cleanJson = cleanJson.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
        const parsed = JSON.parse(cleanJson);
        return new Response(
          JSON.stringify({
            success: true,
            title: (parsed.title || "").trim(),
            content: (parsed.content || "").trim(),
            suggestedTags: Array.isArray(parsed.tags) ? parsed.tags : [],
            mode,
            price,
            message: MESSAGES[mode],
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch {
        const lines = generatedContent.trim().split("\n");
        const fallbackTitle = lines[0].replace(/^["#*]+|["#*]+$/g, "").trim();
        const fallbackContent = lines.slice(1).join("\n").trim();
        return new Response(
          JSON.stringify({
            success: true,
            title: fallbackTitle,
            content: fallbackContent || generatedContent.trim(),
            suggestedTags: [],
            mode,
            price,
            message: MESSAGES[mode],
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        result: generatedContent.trim(),
        mode,
        price,
        message: MESSAGES[mode],
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("[forum-ai-helper] Error:", error);
    const message = error instanceof Error ? error.message : "Неизвестная ошибка";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
