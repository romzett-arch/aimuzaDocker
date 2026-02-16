import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

type Mode = "improve" | "generate" | "create_prompt" | "markup" | "ideas"
  | "suggest_tags" | "build_style" | "analyze_style" | "analyze_prompt" | "auto_tag_all";

// Service name by mode (for pricing)
const MODE_SERVICE_MAP: Record<string, string> = {
  suggest_tags: "prompt_suggest_tags",
  build_style: "prompt_build_style",
  analyze_style: "prompt_check_style",
  analyze_prompt: "prompt_analyzer",
  auto_tag_all: "prompt_suggest_tags",
};

// ── AI Agents ────────────────────────────────────────────────
// DeepSeek V3.2 — технические режимы (разметка, теги, стили, анализ)
const DEEPSEEK_AGENT_ID = 'e046a9e4-43f6-47bc-a39f-8a9de8778d02';
// Yandex GPT 5.1 Pro — творческие режимы (генерация, улучшение, идеи)
const YANDEX_AGENT_ID = 'c45663ac-89e8-4da2-9322-0892cdeffeb9';
// Режимы, обрабатываемые Yandex GPT (пока отключено — тестируем DeepSeek с теми же правилами)
// const YANDEX_MODES: Set<string> = new Set(['generate', 'improve', 'ideas']);
const YANDEX_MODES: Set<string> = new Set([]);

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Authenticate user
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
    const body = await req.json() as {
      mode: Mode;
      lyrics?: string;
      style?: string;
      theme?: string;
      userRequest?: string;
      sectionText?: string;
      existingTagIds?: string[];
      availableTags?: Array<{ id: string; tag: string; nameRu: string }>;
      selectedStyleIds?: string[];
      sections?: Array<{ id: string; text: string; tagIds: string[] }>;
      availableStyles?: Array<{ id: string; tag: string; nameRu: string }>;
      taggedText?: string;
      sunoVersion?: string;
      autoEval?: boolean;
    };
    const { mode, lyrics, style, theme, userRequest, sectionText, existingTagIds, availableTags, selectedStyleIds, sections, availableStyles, taggedText, sunoVersion, autoEval } = body;

    // Select AI agent based on mode
    const useYandex = YANDEX_MODES.has(mode);
    const agentId = useYandex ? YANDEX_AGENT_ID : DEEPSEEK_AGENT_ID;
    const agentName = useYandex ? 'YandexGPT' : 'DeepSeek';

    console.log("Timeweb lyrics request:", { mode, user_id, agent: agentName, hasLyrics: !!lyrics, style, theme });

    const TIMEWEB_TOKEN = useYandex
      ? (Deno.env.get("TIMEWEB_YANDEX_TOKEN") || Deno.env.get("TIMEWEB_AGENT_TOKEN"))
      : Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      throw new Error(`${agentName} token not configured`);
    }

    // Skip billing for auto-evaluation (free after AI actions)
    const skipBilling = autoEval === true && (mode === "analyze_prompt" || mode === "analyze_style");

    // Get service price by mode
    const serviceName = MODE_SERVICE_MAP[mode] || "generate_lyrics";
    const { data: service } = await supabase
      .from("addon_services")
      .select("price_rub")
      .eq("name", serviceName)
      .maybeSingle();

    const price = skipBilling ? 0 : (service?.price_rub ?? 5);

    // Check user balance
    const { data: profile } = await supabase
      .from("profiles")
      .select("balance")
      .eq("user_id", user_id)
      .maybeSingle();

    if (!skipBilling && (!profile || (profile.balance || 0) < price)) {
      return new Response(
        JSON.stringify({ error: "Недостаточно средств на балансе" }),
        { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Deduct balance (skip for free auto-eval)
    const newBalance = skipBilling ? (profile?.balance || 0) : ((profile?.balance || 0) - price);
    if (!skipBilling) {
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
        type: "lyrics_gen",
        description: `Генерация текста (${mode})`,
        metadata: { mode },
      });
    }

    // Build API URL and model name
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${agentId}/v1/chat/completions`;
    const modelName = useYandex ? "yandexgpt" : "deepseek-v3.2";

    // Build prompt based on mode
    let systemPrompt: string;
    let userPrompt: string;

    if (mode === "improve") {
      // ═══════════════════════════════════════════════════════
      // ДВУХПРОХОДНОЕ УЛУЧШЕНИЕ
      // Проход 1: исправить ритм + рифму
      // Проход 2: усилить образность, сохранив рифмы
      // ═══════════════════════════════════════════════════════

      const improvePass1System = `Ты поэт-конструктор. Улучши РИТМ И РИФМУ текста песни, сохраняя смысл и настроение. Образность — на втором месте, её усилят потом.

АБСОЛЮТНЫЕ ПРАВИЛА РИТМА:
1. Определи размер оригинала. Если хаотичный — выбери один и приведи ВСЕ строки к нему
2. ВСЕ строки внутри строфы — ОДИНАКОВОЕ количество слогов (±1)

АБСОЛЮТНЫЕ ПРАВИЛА РИФМЫ:
1. Куплеты: ABAB. Строка 1↔3, строка 2↔4
2. Припев: ABBA. Строка 1↔4, строка 2↔3
3. Рифма = совпадение ударного гласного + последующих звуков
4. ЗАПРЕЩЕНЫ: глагольные (ждёт/найдёт), банальные (любовь/вновь)
5. ПРОВЕРКА: после каждой строфы выпиши концевые слова и убедись в рифме

ПРИМЕР КУПЛЕТА (ямб, 9 слогов, ABAB):
«Бьёт по шторам луч, как по щеке,   (A — щеке)
 Пыль на подоконнике встаёт.         (B — встаёт)
 Тишина ложится на замке,            (A — замке ✓)
 Но из складок шёпот прорастёт.»     (B — прорастёт ✓)

ПРИМЕР ПРИПЕВА (ABBA):
«Мы — пепел в банке из-под чая,      (A — чая)
 Мы — эхо в трубах теплотрасс,       (B — теплотрасс)
 Пока не гаснет свет у нас,           (B — нас ✓)
 Мы тлеем, воздух согревая.»          (A — согревая ✓)

СТРУКТУРА: 3 куплета (по 4 строки) + припев (4 строки) + бридж (2-4 строки) + финальный припев
Объём: 160-200 слов. Сохрани лучшие строки оригинала, замени слабые.

ЗАПРЕЩЕНО: теги [Verse]/[Chorus], пояснения, клише. Отвечай ТОЛЬКО текстом песни.`;

      const improvePass1User = `Исправь ритм и рифму этого текста${style ? ` (стиль: ${style})` : ""}. Сделай все рифмы точными, все строки — одинаковой длины:\n\n${lyrics}`;

      console.log("IMPROVE PASS 1 (structure): calling API...");
      const imp1Response = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}`, "x-proxy-source": "lovable-app" },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: improvePass1System }, { role: "user", content: improvePass1User }],
          temperature: 0.6,
        }),
      });

      if (!imp1Response.ok) {
        await supabase.from("profiles").update({ balance: profile.balance }).eq("user_id", user_id);
        console.error("Improve Pass 1 error:", imp1Response.status);
        throw new Error("Ошибка API (улучшение, проход 1)");
      }

      const imp1Result = await imp1Response.json();
      const imp1Text = imp1Result.choices?.[0]?.message?.content;
      if (!imp1Text) {
        await supabase.from("profiles").update({ balance: profile.balance }).eq("user_id", user_id);
        throw new Error("Не удалось улучшить текст (проход 1)");
      }
      console.log("IMPROVE PASS 1 done, length:", imp1Text.length);

      // Проход 2: усилить образность
      const improvePass2System = `Ты поэт-художник. Тебе дан текст песни с исправленным ритмом и рифмами. Усиль ОБРАЗНОСТЬ, строго сохранив технику.

АБСОЛЮТНЫЕ ПРАВИЛА (нарушение = брак):
1. Последнее слово каждой строки МЕНЯТЬ ЗАПРЕЩЕНО — рифмующие якоря
2. Количество слогов в строке СОХРАНИТЬ (±1). Считай слоги!
3. Пустые строки между секциями СОХРАНИТЬ — это разделение куплетов и припевов
4. Количество строк и порядок секций НЕ МЕНЯТЬ
5. НЕ делать строки длиннее 11 слогов

ЧТО УЛУЧШАТЬ (внутри рамок):
- Конкретные чувственные образы (цвет, звук, запах, текстура)
- Неожиданные метафоры, единая метафорическая система
- Контраст тихое→громкое

ЗАПРЕЩЕНО: клише, теги, пояснения, выдуманные слова.
Отвечай ТОЛЬКО текстом с пустыми строками между секциями.`;

      const improvePass2User = `Усиль образность. ПРАВИЛА: последние слова строк НЕ МЕНЯТЬ, слоги СОХРАНИТЬ (±1), пустые строки между секциями СОХРАНИТЬ, строка НЕ длиннее 11 слогов:\n\n${imp1Text}`;

      console.log("IMPROVE PASS 2 (imagery): calling API...");
      const imp2Response = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}`, "x-proxy-source": "lovable-app" },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: improvePass2System }, { role: "user", content: improvePass2User }],
          temperature: 0.8,
        }),
      });

      let improvedText: string;
      if (!imp2Response.ok) {
        console.error("Improve Pass 2 failed, using pass 1 result");
        improvedText = imp1Text;
      } else {
        const imp2Result = await imp2Response.json();
        improvedText = imp2Result.choices?.[0]?.message?.content || imp1Text;
      }
      console.log("IMPROVE PASS 2 done, length:", improvedText.length);

      await supabase.from("generated_lyrics").insert({
        user_id, prompt: `[IMPROVE-2PASS] ${style || ""}`, lyrics: improvedText, title: null,
      });

      return new Response(
        JSON.stringify({ success: true, lyrics: improvedText.trim(), mode, message: "Текст улучшен!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    } else if (mode === "markup") {
      // Режим разметки текста тегами
      systemPrompt = `Ты эксперт по разметке текстов песен для Suno AI V5.

Задача: добавить структурные теги к тексту песни для генерации музыки.

АЛГОРИТМ РАЗМЕТКИ:
1. Определи структуру песни по пустым строкам между блоками
2. Первый блок → [Verse 1]
3. Если блок повторяется (одинаковый текст) → [Chorus]
4. Второй уникальный блок → [Verse 2]
5. Третий уникальный блок → [Verse 3] или [Bridge] (если короче куплетов и отличается по настроению)
6. Короткий блок из 2-4 строк перед припевом → [Pre-Chorus]
7. Блок из 1-2 вопросительных строк → [Bridge]
8. ОБЯЗАТЕЛЬНО добавить [Outro] в конце

ТЕГИ СТРУКТУРЫ (на английском):
[Intro], [Verse 1], [Verse 2], [Verse 3], [Pre-Chorus], [Chorus], [Post-Chorus], [Bridge], [Outro], [End]

ТЕГИ ДИНАМИКИ (добавляй где уместно):
[Soft], [Powerful], [Build-up], [Drop], [Fade out]

ТЕГИ ВОКАЛА (если уместно):
[Male vocal], [Female vocal], [Whisper], [Spoken word]

COMBO-ТЕГИ (V4.5+):
[Verse 1 | Acoustic Guitar], [Chorus | Energy: High], [Bridge | Piano only], [Outro | Fade out]

АБСОЛЮТНЫЕ ПРАВИЛА (нарушение = брак):
1. УЧИТЫВАЙ ПОЖЕЛАНИЕ ПОЛЬЗОВАТЕЛЯ если есть
2. Текст песни НЕ МЕНЯТЬ — только добавлять теги ПЕРЕД секциями
3. Пустые строки между секциями СОХРАНИТЬ
4. Теги ставить на ОТДЕЛЬНОЙ строке перед текстом секции
5. КАЖДЫЙ тег ОБЯЗАН иметь текст после него. Пустые теги ЗАПРЕЩЕНЫ. Если для [Bridge] нет текста — НЕ СТАВЬ тег [Bridge]
6. ОБЯЗАТЕЛЬНО [Outro] в конце. Если в тексте нет явного аутро — возьми последние 1-2 строки и оберни в [Outro]. Если текст заканчивается припевом — добавь после него [Outro] с повтором 1-2 строк из припева
7. [Outro] ОБЯЗАН содержать минимум одну строку текста. Голый [Outro] без текста ЗАПРЕЩЁН
8. После [Outro] добавь [Fade out] или [End] на отдельной строке
9. Отвечай ТОЛЬКО размеченным текстом, без пояснений

САМОПРОВЕРКА перед выдачей:
- Пройдись по каждому тегу: есть ли после него хотя бы 1 строка текста? Если нет — удали тег или добавь текст
- Есть ли [Outro] с текстом? Если нет — добавь
- Есть ли [End] или [Fade out] в самом конце? Если нет — добавь

ПРИМЕР:
[Verse 1]
Бьёт по шторам луч, как по щеке,
Пыль на подоконнике встаёт.

[Chorus | Powerful]
Мы — пепел в банке из-под чая,
Мы — эхо в трубах теплотрасс.

[Bridge | Soft]
А мы просыпались здесь или нет?

[Outro | Fade out]
Мы — эхо в трубах теплотрасс...
[End]`;

      const userWish = userRequest?.trim() ? `\nПожелание пользователя: ${userRequest}` : "";
      userPrompt = `Разметь этот текст песни тегами структуры:${userWish}

${lyrics}`;
    } else if (mode === "create_prompt") {
      systemPrompt = `Ты эксперт по созданию музыкальных промптов для AI-генераторов музыки (Suno, Udio).

Твоя задача — проанализировать текст песни и создать оптимальный промт стиля на АНГЛИЙСКОМ языке.

Правила:
- Определи жанр, настроение, темп, вокал
- Укажи инструменты и звучание
- Используй музыкальную терминологию
- Формат: теги через запятую, без скобок
- Максимум 150 символов
- Пиши ТОЛЬКО НА АНГЛИЙСКОМ
- Отвечай ТОЛЬКО промтом, без пояснений

Примеры хороших промптов:
- "dark trap, 808 bass, aggressive vocals, minor key, 140 bpm"
- "acoustic indie folk, warm vocals, fingerpicking guitar, nostalgic, autumn vibes"
- "synthwave, retro 80s, female vocals, dreamy, neon lights, pulsing synths"`;

      userPrompt = `Проанализируй этот текст песни и создай промт стиля:

${lyrics}

${style ? `Текущий стиль (учти при создании): ${style}` : ""}`;
    } else if (mode === "ideas") {
      systemPrompt = `Ты креативный поэт-песенник. Придумай 3 оригинальные идеи для песен.

Для КАЖДОЙ идеи укажи:
1. Название — 3-5 слов, яркое, вызывающее конкретный образ. НЕ банальное
2. Настроение — выбери одно: оптимистичное, меланхоличное, бунтарское, мечтательное или ироничное
3. Концепция — сюжет с конфликтом и неожиданным поворотом (2-3 предложения). НЕ просто «герой идёт к мечте»
4. Теги стиля — 3-4 музыкальных тега на АНГЛИЙСКОМ через запятую
5. Первые строки — ровно 4 строки начала текста

Формат ответа (строго):

---IDEA_1---
НАЗВАНИЕ: [название]
НАСТРОЕНИЕ: [настроение]
КОНЦЕПЦИЯ: [концепция]
ТЕГИ: [теги через запятую, на английском]
ТЕКСТ:
[первые 4 строки]

---IDEA_2---
...

---IDEA_3---
...

ПРАВИЛА КАЧЕСТВА ТЕКСТА:
- Выбери стихотворный размер (ямб, хорей, дактиль, амфибрахий или анапест) и СТРОГО держи во всех 4 строках
- КРИТИЧЕСКИ ВАЖНО: одинаковое количество слогов в каждой строке (±1). Считай слоги!
- Рифмовка строго ABAB
- Рифмы точные или богатые, НЕ глагольные (ждёт/найдёт — запрещено), НЕ банальные (любовь/вновь — запрещено)
- Каждая строка содержит конкретный образ (цвет, свет, запах, звук, прикосновение)
- ЗАПРЕЩЕНЫ клише: «идти вперёд», «верить в мечту», «крылья мечты», «свет в окне», «сердце стучит/бьётся», «на коне», «тернистый путь», «горизонты», «вдаль гляжу»
- Если фраза звучит как мотивационный плакат — замени свежим образом

ПРИМЕР хороших 4 строк (ямб, 9 слогов, ABAB):
«Залатан провод на стене,          (A)
 Мерцает лампочка в углу.           (B)
 Мой кот задумался в окне,          (A)
 Считая капли по стеклу.»           (B)

Общие правила:
- 3 идеи РАЗНЫХ по настроению и жанру
- Темы: необычные ракурсы, неожиданные метафоры (предметы оживают, бытовые детали, наука, город, природа через нетипичную оптику)
- Теги стиля ТОЛЬКО на английском
- НЕ добавляй пояснений, только идеи в заданном формате`;

      const ideasTheme = theme?.trim() || "";
      userPrompt = ideasTheme
        ? `Сгенерируй 3 креативные идеи для песен на тему/по наброску: "${ideasTheme}". Развей эту тему в 3 разных направлениях. Конкретные образы, никаких клише.`
        : `Сгенерируй 3 креативные идеи для песен. Удиви необычными метафорами. Никаких мотивационных клише — конкретные образы и сюжеты.`;
    } else if (mode === "auto_tag_all") {
      const tagsJson = JSON.stringify(availableTags || []);
      const sectionsData = (sections || []).map((s: { id: string; text: string; tagIds: string[] }, i: number) => ({
        idx: i,
        text: s.text.substring(0, 200),
        existingTagIds: s.tagIds,
      }));
      systemPrompt = `Ты эксперт по тегам Suno AI. Задача: подобрать теги для КАЖДОЙ секции текста песни за один раз.

Для каждой секции определи:
1. Тип секции: [Verse], [Chorus], [Bridge], [Pre-Chorus], [Outro], [Intro]
2. Модификаторы если уместно: [Soft], [Powerful], [Build-up], вокальные теги
3. Выбирай ТОЛЬКО из availableTags (по id)
4. Учитывай позицию секции в песне (первая = скорее Verse, повторяющаяся = Chorus)
5. Если секция уже имеет теги (existingTagIds) — не дублируй их, добавляй только недостающие

Ответ СТРОГО JSON: { "sections": [{ "idx": 0, "tagIds": ["id1","id2"], "reason": "обоснование" }, ...] }
Массив sections должен содержать рекомендации для КАЖДОЙ секции из входных данных.`;
      userPrompt = `Секции текста песни:
${JSON.stringify(sectionsData)}

Доступные теги: ${tagsJson}

Подбери теги для КАЖДОЙ секции. Верни JSON.`;
    } else if (mode === "suggest_tags") {
      const tagsJson = JSON.stringify(availableTags || []);
      systemPrompt = `Ты эксперт по тегам Suno AI для текстов песен. Задача: подобрать 2-5 подходящих тегов для секции текста.

Правила:
- Теги на английском: [Verse], [Chorus], [Male vocal], [Whisper] и т.д.
- Выбирай ТОЛЬКО из списка availableTags
- Учитывай контекст секции (настроение, структура, инструменты)
- Не дублируй уже выбранные (existingTagIds)
- Отвечай СТРОГО JSON: { "suggestions": [{ "tagId": "id", "reason": "краткое обоснование" }] }`;
      userPrompt = `Секция текста:
${sectionText || ""}

Уже выбранные теги (id): ${JSON.stringify(existingTagIds || [])}
Доступные теги: ${tagsJson}

Верни JSON с массивом suggestions (2-5 тегов).`;
    } else if (mode === "build_style") {
      const stylesJson = JSON.stringify(availableStyles || []);
      systemPrompt = `Ты эксперт по промптам Suno AI V5. Задача: построить ПОЛНЫЙ style-промпт из текста песни.

ФОРМУЛА СТИЛЯ (все 6 слоёв ОБЯЗАТЕЛЬНЫ):
1. ЖАНР — первым тегом, максимальный вес. Используй поджанр (grunge вместо rock, trap вместо hip-hop)
2. НАСТРОЕНИЕ — melancholic, uplifting, aggressive, dreamy, nostalgic и т.д.
3. ЭНЕРГИЯ — chill, energetic, intense, laid-back
4. ИНСТРУМЕНТЫ — 2-3 штуки: acoustic guitar, piano, 808 bass, synth pads, fingerpicking guitar и т.д.
5. ВОКАЛ — ОБЯЗАТЕЛЬНО: male vocals, female vocals, baritone, breathy, smooth, gritty и т.д.
6. BPM — ОБЯЗАТЕЛЬНО: конкретное число (60-180). Определи по настроению текста: баллада=60-80, поп=100-120, рок=120-140, электроника=120-150, рэп=80-100

ПРИМЕРЫ ХОРОШИХ style-строк:
- "dark trap, 808 bass, aggressive male vocals, gritty, minor key, 85 bpm"
- "indie folk, acoustic guitar, fingerpicking, warm female vocals, nostalgic, 95 bpm"
- "synthwave, retro synths, pulsing bass, breathy female vocals, neon, 118 bpm"
- "alternative rock, distorted guitars, driving drums, baritone vocals, raw, 130 bpm"
- "lo-fi hip hop, vinyl crackle, jazz piano, smooth vocals, chill, 75 bpm"

ПРАВИЛА:
- 5-7 дескрипторов, не более 10
- Только английский
- НЕ начинать с "I want..." — сразу дескрипторы
- НЕ использовать имена артистов
- Один основной жанр, не конкурирующие
- Нет конфликтов: calm+aggressive, slow+energetic, happy+melancholic, lo-fi+polished
- Лимит: 200 символов для V4, 1000 для V5

Выбирай стили из availableStyles где возможно. Если нужного нет — пиши свободным текстом.

Отвечай СТРОГО JSON: { "styleIds": ["id1","id2"], "styleString": "полная строка стиля с BPM", "reasoning": "краткое обоснование выбора" }`;
      userPrompt = `Текст песни:
${lyrics || ""}

Теги в тексте: ${JSON.stringify(sections?.flatMap(s => s.tagIds) || [])}
Доступные стили: ${stylesJson}

Построй ПОЛНЫЙ style с жанром, настроением, инструментами, вокалом и BPM. Верни JSON.`;
    } else if (mode === "analyze_style") {
      const stylesJson = JSON.stringify(selectedStyleIds || []);
      const sectionsJson = JSON.stringify(sections || []);
      systemPrompt = `Ты эксперт по промптам Suno AI V5. Задача: проверить style-строку на полноту и конфликты, дать КОНКРЕТНЫЕ рекомендации.

ЧЕК-ЛИСТ STYLE (проверяй по порядку):
1. ЖАНР: есть ли конкретный жанр/поджанр первым тегом? Если нет — предложи конкретный на основе текста
2. BPM: указан? Если нет — предложи конкретное число (баллада=60-80, поп=100-120, рок=120-140)
3. ВОКАЛ: указан тип? Если нет — предложи (male/female vocals + характер: smooth, gritty, breathy)
4. ИНСТРУМЕНТЫ: есть 2-3? Если нет — предложи конкретные под жанр
5. НАСТРОЕНИЕ/ЭНЕРГИЯ: есть? Если нет — предложи на основе текста
6. КОНФЛИКТЫ: calm+aggressive, slow+energetic, happy+melancholic, lo-fi+polished
7. КОЛИЧЕСТВО: 5-7 дескрипторов оптимально. Меньше 4 = слишком обще. Больше 10 = путаница

ВАЖНО: в suggestion ВСЕГДА давай КОНКРЕТНОЕ значение, которое можно вставить.
Не "добавьте BPM" → а "добавьте: 110 bpm"
Не "добавьте вокал" → а "добавьте: warm male vocals"
Не "добавьте инструменты" → а "добавьте: acoustic guitar, soft drums"

Отвечай СТРОГО JSON: { "score": 1-10, "issues": [{ "type": "error|warning", "message": "описание проблемы", "suggestion": "конкретное исправление с готовым значением" }], "summary": "краткое резюме на русском" }`;
      userPrompt = `Выбранные стили (ids): ${stylesJson}
Секции текста: ${sectionsJson}
Текущий style-строка: "${style || "(пусто)"}"

Проверь style по чек-листу. В каждом suggestion — КОНКРЕТНОЕ значение для вставки.`;
    } else if (mode === "analyze_prompt") {
      const fullText = taggedText || lyrics || "";
      systemPrompt = `Ты эксперт по промптам Suno AI V5. Задача: проверить ГОТОВЫЙ промпт (style + tagged lyrics) перед генерацией музыки.

ЧЕК-ЛИСТ STYLE (вес 50%):
1. Жанр первым тегом? Если нет — предложи конкретный
2. BPM указан? Если нет — предложи число
3. Вокальный тип указан? Если нет — предложи
4. 2-3 инструмента? Если нет — предложи
5. 5-7 дескрипторов всего? Меньше = обобщённо, больше 10 = путаница
6. Нет конфликтов (calm+aggressive, lo-fi+polished)?
7. Только английский? Нет имён артистов? Нет "I want..."?
8. Длина ≤1000 символов (V5)?

ЧЕК-ЛИСТ LYRICS (вес 50%):
1. Есть теги структуры ([Verse], [Chorus])? Если текст без тегов — это WARNING, не ERROR (пользователь мог ещё не разметить)
2. Если теги ЕСТЬ — проверь: каждый тег ДОЛЖЕН иметь текст после себя. Пустой тег (например [Bridge] без текста) — ERROR
3. Есть [Outro] для корректного завершения? Если нет — предложи. Но [Outro] тоже ОБЯЗАН иметь текст
4. Нет BPM в lyrics (только в style)?
5. Теги на английском?
6. Оптимум 100-200 слов? Длиннее 300 = предупреди
7. Короткие строки (улучшают артикуляцию)?

ОЦЕНКА:
- 9-10: style полный (жанр, BPM, вокал, инструменты) + lyrics размечены тегами + нет конфликтов
- 7-8: style почти полный (не хватает 1-2 элемента) + lyrics имеют базовую структуру
- 5-6: style неполный (нет BPM или вокала) + lyrics без тегов
- 3-4: style слишком краткий + серьёзные проблемы
- 1-2: пустой или конфликтующий промпт

В КАЖДОМ fix давай КОНКРЕТНОЕ значение:
Не "добавьте BPM" → а fix с data: { value: "110 bpm" }
Не "добавьте [Outro]" → а fix с data: { text: "[Outro]\\n[Fade out]\\n[End]" }

Формат fix: { "type": "add_tag|remove_tag|replace_style|set_bpm|add_section", "target": "lyrics|style", "description": "что сделать", "data": { конкретные значения } }

Отвечай СТРОГО JSON: { "score": 1-10, "summary": "краткое резюме на русском", "issues": [{ "type": "error|warning", "message": "описание", "fix": { fix-объект с конкретными data } }] }`;
      userPrompt = `Tagged lyrics:
${fullText}

Style: "${style || "(пусто)"}"
Suno version: ${sunoVersion || "V5"}

Проверь промпт. В fix — КОНКРЕТНЫЕ значения для вставки.`;
    } else {
      // ═══════════════════════════════════════════════════════
      // ДВУХПРОХОДНАЯ ГЕНЕРАЦИЯ
      // Проход 1: структура + ритм + рифма (конструктор)
      // Проход 2: образность + детали (художник)
      // ═══════════════════════════════════════════════════════

      // ── ПРОХОД 1: Поэт-конструктор ─────────────────────
      const pass1System = `Ты поэт-конструктор. Твоя ЕДИНСТВЕННАЯ задача — написать текст песни с ИДЕАЛЬНЫМ ритмом и рифмой. Образы могут быть простыми — их усилят позже. Сейчас важна ТОЛЬКО техника стиха.

СТРУКТУРА:
- Куплет 1 (4 строки) → Припев (4 строки) → Куплет 2 (4 строки) → Припев (повтор) → Куплет 3 (4 строки) → Бридж (2-4 строки) → Финальный припев (4 строки, может отличаться 1-2 строками)
- Секции разделяй пустыми строками
- Объём: 160-200 слов

АБСОЛЮТНЫЕ ПРАВИЛА РИТМА:
1. Выбери ОДИН размер (ямб, хорей, дактиль, амфибрахий или анапест) для ВСЕЙ песни
2. ВСЕ строки — 8-10 слогов (НЕ больше 11). Считай слоги в каждой строке перед выдачей!
3. Если строка получилась длиннее 11 слогов — разбей её или перепиши короче
4. Пример ямба (9 слогов): «Бьёт по штó-рам лýч, как по щé-ке» = 9 слогов ✓

АБСОЛЮТНЫЕ ПРАВИЛА РИФМЫ:
1. Куплеты: ABAB. Строка 1 рифмуется со строкой 3, строка 2 — со строкой 4
2. Припев: ABBA. Строка 1 рифмуется со строкой 4, строка 2 — со строкой 3
3. Рифма = совпадение ударного гласного + всех звуков после него. Примеры точных рифм: щеке/замке, встаёт/прорастёт, чая/согревая, теплотрасс/нас
4. ЗАПРЕЩЕНЫ: глагольные рифмы (ждёт/найдёт), банальные (любовь/вновь)
5. ПРОВЕРКА: после каждой строфы выпиши пары концевых слов и убедись, что они рифмуются

ПРИМЕР КУПЛЕТА (ямб, 9 слогов, ABAB):
«Бьёт по шторам луч, как по щеке,   (A — щеке)
 Пыль на подоконнике встаёт.         (B — встаёт)
 Тишина ложится на замке,            (A — замке ✓)
 Но из складок шёпот прорастёт.»     (B — прорастёт ✓)

ПРИМЕР ПРИПЕВА (ямб, 9 слогов, ABBA):
«Мы — пепел в банке из-под чая,      (A — чая)
 Мы — эхо в трубах теплотрасс,       (B — теплотрасс)
 Пока не гаснет свет у нас,           (B — нас ✓)
 Мы тлеем, воздух согревая.»          (A — согревая ✓)

АНТИКЛИШЕ (запрещены):
- «свет в окне», «слёзы дождя», «крылья мечты», «сердце стучит/бьётся», «пойдём за мечтой»
- «не боясь темноты», «новый шанс», «верить в себя», «идти вперёд», «на коне»
- «тернистый путь», «ведёт к мечте», «готовы к судьбе», «вдаль гляжу», «открывая горизонты»

ВАЖНО — РАЗДЕЛЕНИЕ СЕКЦИЙ:
- Между куплетом и припевом — ОБЯЗАТЕЛЬНО пустая строка
- Между припевом и следующим куплетом — ОБЯЗАТЕЛЬНО пустая строка
- Между куплетом и бриджем — ОБЯЗАТЕЛЬНО пустая строка
- Без пустых строк текст НЕ ГОДИТСЯ для песни!

ЗАПРЕЩЕНО: теги [Verse]/[Chorus], пояснения, архаизмы, выдуманные слова. Отвечай ТОЛЬКО текстом песни.`;

      const baseText = lyrics?.trim() || theme || "";
      const pass1User = baseText 
        ? `Напиши текст песни${style ? ` в стиле ${style}` : ""}, вдохновляясь этой темой. ГЛАВНОЕ — ритм и рифма:\n\n${baseText}`
        : `Напиши оригинальный текст песни${style ? ` в стиле ${style}` : ""}. Тема на твой выбор. ГЛАВНОЕ — ритм и рифма.`;

      console.log("PASS 1 (structure): calling API...");
      const pass1Response = await fetch(apiUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${TIMEWEB_TOKEN}`,
          "x-proxy-source": "lovable-app",
        },
        body: JSON.stringify({
          model: modelName,
          messages: [
            { role: "system", content: pass1System },
            { role: "user", content: pass1User },
          ],
          temperature: 0.6,
        }),
      });

      if (!pass1Response.ok) {
        await supabase.from("profiles").update({ balance: profile.balance }).eq("user_id", user_id);
        const errorText = await pass1Response.text();
        console.error("Pass 1 API error:", pass1Response.status, errorText);
        throw new Error("Ошибка API (проход 1)");
      }

      const pass1Result = await pass1Response.json();
      const pass1Text = pass1Result.choices?.[0]?.message?.content;
      if (!pass1Text) {
        await supabase.from("profiles").update({ balance: profile.balance }).eq("user_id", user_id);
        throw new Error("Не удалось сгенерировать структуру текста");
      }
      console.log("PASS 1 done, length:", pass1Text.length);

      // ── ПРОХОД 2: Поэт-художник ────────────────────────
      const pass2System = `Ты поэт-художник. Тебе дан текст песни с ритмической структурой и рифмами. Усиль ОБРАЗНОСТЬ, строго сохранив технику.

АБСОЛЮТНЫЕ ПРАВИЛА (нарушение = брак):
1. Последнее слово каждой строки МЕНЯТЬ ЗАПРЕЩЕНО — это якоря рифмы
2. Количество слогов в строке СОХРАНИТЬ (±1 слог максимум). Если оригинал 9 слогов — твоя строка тоже 9 (±1). Считай!
3. Пустые строки между секциями СОХРАНИТЬ в точности — это разделение куплетов и припевов
4. Количество строк и порядок секций НЕ МЕНЯТЬ
5. НЕ делать строки длиннее 11 слогов

ЧТО УЛУЧШАТЬ (внутри этих рамок):
- Замени общие слова ВНУТРИ строк на конкретные чувственные образы (цвет, звук, запах, текстура)
- Неожиданные метафоры: предметы оживают, бытовые детали как персонажи
- Единая метафорическая система — все образы из одного смыслового поля
- Драматургия: контраст тихое→громкое, сомнение→уверенность

ЗАПРЕЩЕНО: клише, теги [Verse]/[Chorus], пояснения, выдуманные слова.

Отвечай ТОЛЬКО улучшенным текстом песни с сохранёнными пустыми строками между секциями.`;

      const pass2User = `Усиль образность этого текста. СТРОГИЕ ПРАВИЛА:
1. Последнее слово каждой строки НЕ МЕНЯТЬ (рифмы)
2. Количество слогов в каждой строке СОХРАНИТЬ (±1)
3. Пустые строки между секциями СОХРАНИТЬ
4. Строка НЕ длиннее 11 слогов

Текст:\n\n${pass1Text}`;

      console.log("PASS 2 (imagery): calling API...");
      const pass2Response = await fetch(apiUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${TIMEWEB_TOKEN}`,
          "x-proxy-source": "lovable-app",
        },
        body: JSON.stringify({
          model: modelName,
          messages: [
            { role: "system", content: pass2System },
            { role: "user", content: pass2User },
          ],
          temperature: 0.8,
        }),
      });

      if (!pass2Response.ok) {
        // Если проход 2 упал — возвращаем результат прохода 1 (он уже оплачен)
        console.error("Pass 2 failed, returning pass 1 result");
        systemPrompt = pass1System;
        userPrompt = pass1User;
        // generatedContent will be set from pass1Text below via fallback
        const fallbackContent = pass1Text;
        // Save and return pass1 as fallback
        await supabase.from("generated_lyrics").insert({
          user_id, prompt: `[GENERATE-2PASS-FALLBACK] ${theme || style || ""}`, lyrics: fallbackContent, title: null,
        });
        return new Response(
          JSON.stringify({ success: true, lyrics: fallbackContent, mode, message: "Текст создан!" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const pass2Result = await pass2Response.json();
      const pass2Text = pass2Result.choices?.[0]?.message?.content;
      const finalText = pass2Text || pass1Text;
      console.log("PASS 2 done, length:", finalText.length);

      // Save to history
      await supabase.from("generated_lyrics").insert({
        user_id, prompt: `[GENERATE-2PASS] ${theme || style || ""}`, lyrics: finalText, title: null,
      });

      return new Response(
        JSON.stringify({ success: true, lyrics: finalText.trim(), mode, message: "Текст создан!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Call Timeweb Agent API (single-pass modes: markup, ideas, suggest_tags, etc.)
    console.log(`Calling ${agentName} agent: ${agentId}`);

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${TIMEWEB_TOKEN}`,
        "x-proxy-source": "lovable-app",
      },
      body: JSON.stringify({
        model: modelName,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: useYandex ? 0.7 : 0.8,
      }),
    });

    console.log("Timeweb response status:", response.status);

    if (!response.ok) {
      // Refund on API error
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user_id);

      const errorText = await response.text();
      console.error("Timeweb API error:", response.status, errorText);
      throw new Error("Ошибка API Timeweb");
    }

    const result = await response.json();
    console.log("Timeweb response received");

    const generatedContent = result.choices?.[0]?.message?.content;
    
    if (!generatedContent) {
      // Refund on empty result
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user_id);
      throw new Error("Не удалось сгенерировать текст");
    }

    // Save to history (only for lyrics modes, not markup/create_prompt/B9)
    const isB9Mode = ["suggest_tags", "build_style", "analyze_style", "analyze_prompt", "auto_tag_all"].includes(mode);
    if (mode !== "create_prompt" && mode !== "markup" && !isB9Mode) {
      await supabase
        .from("generated_lyrics")
        .insert({
          user_id: user_id,
          prompt: mode === "improve" ? `[IMPROVE] ${style || ""}` : `[GENERATE] ${theme || style || ""}`,
          lyrics: generatedContent,
          title: null,
        });
    }

    // Different response based on mode
    if (mode === "create_prompt") {
      return new Response(
        JSON.stringify({ 
          success: true, 
          stylePrompt: generatedContent.trim(),
          mode,
          message: "Промт создан!" 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (mode === "markup") {
      return new Response(
        JSON.stringify({ 
          success: true, 
          lyrics: generatedContent.trim(),
          mode,
          message: "Текст размечен!" 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (isB9Mode) {
      // Parse JSON from B9 modes (may be wrapped in ```json)
      let jsonStr = generatedContent.trim();
      const jsonMatch = jsonStr.match(/```(?:json)?\s*([\s\S]*?)```/);
      if (jsonMatch) jsonStr = jsonMatch[1].trim();
      try {
        const parsed = JSON.parse(jsonStr);
        return new Response(
          JSON.stringify({ success: true, ...parsed, mode }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch (e) {
        console.error("B9 JSON parse error:", e);
        return new Response(
          JSON.stringify({ error: "Не удалось разобрать ответ AI", raw: generatedContent.slice(0, 500) }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (mode === "ideas") {
      // Parse ideas from response
      const ideas: Array<{
        title: string;
        mood: string;
        concept: string;
        tags: string;
        lyrics: string;
      }> = [];

      const ideaBlocks = generatedContent.split(/---IDEA_\d+---/).filter((b: string) => b.trim());
      
      for (const block of ideaBlocks) {
        const titleMatch = block.match(/НАЗВАНИЕ:\s*(.+)/i);
        const moodMatch = block.match(/НАСТРОЕНИЕ:\s*(.+)/i);
        const conceptMatch = block.match(/КОНЦЕПЦИЯ:\s*(.+)/i);
        const tagsMatch = block.match(/ТЕГИ:\s*(.+)/i);
        const lyricsMatch = block.match(/ТЕКСТ:\s*([\s\S]+?)(?=(?:---IDEA_|$))/i);

        if (titleMatch) {
          ideas.push({
            title: titleMatch[1].trim(),
            mood: moodMatch?.[1]?.trim() || "",
            concept: conceptMatch?.[1]?.trim() || "",
            tags: tagsMatch?.[1]?.trim() || "",
            lyrics: lyricsMatch?.[1]?.trim() || "",
          });
        }
      }

      return new Response(
        JSON.stringify({ 
          success: true, 
          ideas,
          mode,
          message: "Идеи сгенерированы!" 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        lyrics: generatedContent.trim(),
        mode,
        message: mode === "improve" ? "Текст улучшен!" : "Текст сгенерирован!" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in deepseek-lyrics:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
