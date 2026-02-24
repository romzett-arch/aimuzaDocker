import type { Mode, RequestBody } from "./types.ts";
import {
  SYSTEM_IMPROVE_PASS1,
  SYSTEM_IMPROVE_PASS2,
  SYSTEM_GENERATE_PASS1,
  SYSTEM_GENERATE_PASS2,
  SYSTEM_MARKUP,
  SYSTEM_CREATE_PROMPT,
} from "./prompts-text.ts";
import {
  SYSTEM_IDEAS,
  SYSTEM_AUTO_TAG_ALL,
  SYSTEM_SUGGEST_TAGS,
  SYSTEM_BUILD_STYLE,
  SYSTEM_ANALYZE_STYLE,
  SYSTEM_ANALYZE_PROMPT,
  SYSTEM_FIX_PRONUNCIATION,
} from "./prompts-text-2.ts";

export type BuildPromptsOpts = { pass?: 1 | 2; intermediateText?: string };

export function buildPrompts(
  mode: Mode,
  body: RequestBody,
  opts?: BuildPromptsOpts
): { systemPrompt: string; userPrompt: string } {
  const { lyrics, style, theme, userRequest, sectionText, existingTagIds, availableTags, selectedStyleIds, sections, availableStyles, taggedText, sunoVersion } = body;

  if (mode === "improve") {
    if (opts?.pass === 2 && opts.intermediateText) {
      return {
        systemPrompt: SYSTEM_IMPROVE_PASS2,
        userPrompt: `Усиль образность. ПРАВИЛА: последние слова строк НЕ МЕНЯТЬ, слоги СОХРАНИТЬ (±1), пустые строки между секциями СОХРАНИТЬ, строка НЕ длиннее 11 слогов:\n\n${opts.intermediateText}`,
      };
    }
    return {
      systemPrompt: SYSTEM_IMPROVE_PASS1,
      userPrompt: `Исправь ритм и рифму этого текста${style ? ` (стиль: ${style})` : ""}. Сделай все рифмы точными, все строки — одинаковой длины:\n\n${lyrics}`,
    };
  }

  if (mode === "generate") {
    if (opts?.pass === 2 && opts.intermediateText) {
      return {
        systemPrompt: SYSTEM_GENERATE_PASS2,
        userPrompt: `Усиль образность этого текста. СТРОГИЕ ПРАВИЛА:
1. Последнее слово каждой строки НЕ МЕНЯТЬ (рифмы)
2. Количество слогов в каждой строке СОХРАНИТЬ (±1)
3. Пустые строки между секциями СОХРАНИТЬ
4. Строка НЕ длиннее 11 слогов

Текст:\n\n${opts.intermediateText}`,
      };
    }
    const baseText = lyrics?.trim() || theme || "";
    return {
      systemPrompt: SYSTEM_GENERATE_PASS1,
      userPrompt: baseText
        ? `Напиши текст песни${style ? ` в стиле ${style}` : ""}, вдохновляясь этой темой. ГЛАВНОЕ — ритм и рифма:\n\n${baseText}`
        : `Напиши оригинальный текст песни${style ? ` в стиле ${style}` : ""}. Тема на твой выбор. ГЛАВНОЕ — ритм и рифма.`,
    };
  }

  if (mode === "markup") {
    const userWish = userRequest?.trim() ? `\nПожелание пользователя: ${userRequest}` : "";
    const styleHint = style?.trim() ? `\nСтиль/жанр песни (УЧИТЫВАЙ в модификаторах compound-тегов): ${style}` : "";
    return {
      systemPrompt: SYSTEM_MARKUP,
      userPrompt: `Разметь этот текст песни тегами структуры:${styleHint}${userWish}

${lyrics}`,
    };
  }

  if (mode === "create_prompt") {
    return {
      systemPrompt: SYSTEM_CREATE_PROMPT,
      userPrompt: style?.trim()
        ? `Текст песни:\n\n${lyrics}\n\nСтиль от пользователя (ПРИОРИТЕТ №1 — сохрани жанр, голос, энергию, дополни недостающее): ${style}`
        : `Текст песни:\n\n${lyrics}\n\nСтиль не указан — определи всё по тексту.`,
    };
  }

  if (mode === "ideas") {
    const ideasTheme = theme?.trim() || "";
    return {
      systemPrompt: SYSTEM_IDEAS,
      userPrompt: ideasTheme
        ? `Сгенерируй 3 креативные идеи для песен на тему/по наброску: "${ideasTheme}". Развей эту тему в 3 разных направлениях. Конкретные образы, никаких клише.`
        : `Сгенерируй 3 креативные идеи для песен. Удиви необычными метафорами. Никаких мотивационных клише — конкретные образы и сюжеты.`,
    };
  }

  if (mode === "auto_tag_all") {
    const tagsJson = JSON.stringify(availableTags || []);
    const sectionsData = (sections || []).map((s, i) => ({
      idx: i,
      text: s.text.substring(0, 200),
      existingTagIds: s.tagIds,
    }));
    return {
      systemPrompt: SYSTEM_AUTO_TAG_ALL,
      userPrompt: `Секции текста песни:
${JSON.stringify(sectionsData)}

Доступные теги: ${tagsJson}

Подбери теги для КАЖДОЙ секции. Верни JSON.`,
    };
  }

  if (mode === "suggest_tags") {
    const tagsJson = JSON.stringify(availableTags || []);
    return {
      systemPrompt: SYSTEM_SUGGEST_TAGS,
      userPrompt: `Секция текста:
${sectionText || ""}

Уже выбранные теги (id): ${JSON.stringify(existingTagIds || [])}
Доступные теги: ${tagsJson}

Верни JSON с массивом suggestions (2-5 тегов).`,
    };
  }

  if (mode === "build_style") {
    const stylesJson = JSON.stringify(availableStyles || []);
    return {
      systemPrompt: SYSTEM_BUILD_STYLE,
      userPrompt: `Текст песни:
${lyrics || ""}

Теги в тексте: ${JSON.stringify(sections?.flatMap(s => s.tagIds) || [])}
Доступные стили: ${stylesJson}

Построй ПОЛНЫЙ style с жанром, настроением, инструментами, вокалом и BPM. Верни JSON.`,
    };
  }

  if (mode === "analyze_style") {
    const stylesJson = JSON.stringify(selectedStyleIds || []);
    const sectionsJson = JSON.stringify(sections || []);
    return {
      systemPrompt: SYSTEM_ANALYZE_STYLE,
      userPrompt: `Выбранные стили (ids): ${stylesJson}
Секции текста: ${sectionsJson}
Текущий style-строка: "${style || "(пусто)"}"

Проверь style по чек-листу. В каждом suggestion — КОНКРЕТНОЕ значение для вставки.`,
    };
  }

  if (mode === "analyze_prompt") {
    const fullText = taggedText || lyrics || "";
    return {
      systemPrompt: SYSTEM_ANALYZE_PROMPT,
      userPrompt: `Tagged lyrics:
${fullText}

Style: "${style || "(пусто)"}"
Suno version: ${sunoVersion || "V5"}

Проверь промпт. В fix — КОНКРЕТНЫЕ значения для вставки.`,
    };
  }

  if (mode === "fix_pronunciation") {
    return {
      systemPrompt: SYSTEM_FIX_PRONUNCIATION,
      userPrompt: `Расставь ударения (заглавная ударная гласная) в этом тексте песни:\n\n${lyrics}`,
    };
  }

  return { systemPrompt: "", userPrompt: "" };
}
