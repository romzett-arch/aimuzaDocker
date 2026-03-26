import type { AIAnalysisResult } from "./types.ts";
import { TIMEWEB_AGENT_ACCESS_ID } from "./constants.ts";

export async function analyzeWithAI(
  content: string,
  reportReason: string,
  reportDetails: string | null
): Promise<AIAnalysisResult> {
  const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
  if (!TIMEWEB_TOKEN) {
    console.warn("[analyze-report] TIMEWEB_AGENT_TOKEN not configured, using heuristic");
    return heuristicAnalysis(content);
  }

  const systemPrompt = `Ты — AI-модератор музыкального форума. На этот пост/тему поступила жалоба.

Причина жалобы: "${reportReason}"
${reportDetails ? `Детали: "${reportDetails}"` : ""}

Проанализируй контент и определи:
1. Является ли контент РЕАЛЬНЫМ нарушением правил?
2. Категория нарушения (если есть)

Категории нарушений:
- toxicity: прямые оскорбления, мат, hate speech, унижение
- spam: реклама, промо, бессмысленный флуд
- threats: угрозы, буллинг, запугивание
- nsfw: откровенный контент
- fraud: мошенничество, фейки
- offtopic: полностью не по теме
- copyright: нарушение авторских прав

ВАЖНО:
- НЕ считай нарушением: критику музыки, сарказм, мнения, дискуссии, профессиональные споры
- Учитывай КОНТЕКСТ музыкального форума
- Будь строг к реальным оскорблениям, но лоялен к креативным дискуссиям

Отвечай СТРОГО JSON: {"verdict": "violation"|"clean"|"uncertain", "confidence": 0.0-1.0, "category": "...", "reason": "краткое пояснение на русском до 100 символов"}`;

  try {
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
      },
      body: JSON.stringify({
        model: "qwen3.5-flash",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: content.substring(0, 1500) },
        ],
        temperature: 0.1,
        max_tokens: 300,
      }),
    });

    if (!response.ok) {
      console.warn(`[analyze-report] DeepSeek API error: ${response.status}`);
      return heuristicAnalysis(content);
    }

    const data = await response.json();
    const resultText = data.choices?.[0]?.message?.content;
    if (!resultText) return heuristicAnalysis(content);

    const jsonMatch = resultText.match(/\{[^}]*\}/s);
    if (!jsonMatch) return heuristicAnalysis(content);

    const parsed = JSON.parse(jsonMatch[0]);
    return {
      verdict: parsed.verdict || "uncertain",
      confidence: Math.min(1, Math.max(0, parsed.confidence || 0)),
      category: parsed.category || "none",
      reason: (parsed.reason || "Анализ завершён").substring(0, 200),
    };
  } catch (error) {
    console.warn("[analyze-report] AI analysis failed:", error);
    return heuristicAnalysis(content);
  }
}

export function heuristicAnalysis(content: string): AIAnalysisResult {
  const lowerContent = content.toLowerCase();

  const profanityPatterns = [
    /\bбля[дть]?\b/i,
    /\bхуй/i,
    /\bпизд/i,
    /\bебл[аоя]/i,
    /\bсука?\b/i,
    /\bмуда[кч]/i,
    /\bгандон/i,
    /\bдолбо[её]б/i,
    /\bдебил/i,
    /\bидиот/i,
    /\bтупой/i,
    /\bурод/i,
  ];

  const matched = profanityPatterns.filter((p) => p.test(lowerContent));

  if (matched.length >= 2) {
    return {
      verdict: "violation",
      confidence: 0.85,
      category: "toxicity",
      reason: "Обнаружена нецензурная лексика (эвристика)",
    };
  }

  if (matched.length === 1) {
    return {
      verdict: "uncertain",
      confidence: 0.6,
      category: "toxicity",
      reason: "Возможная нецензурная лексика (требует ручной проверки)",
    };
  }

  return {
    verdict: "uncertain",
    confidence: 0.3,
    category: "none",
    reason: "Автоматический анализ не обнаружил явных нарушений",
  };
}
