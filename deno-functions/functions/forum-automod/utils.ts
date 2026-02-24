import { corsHeaders } from "./types.ts";

export function humanizeFlag(flag: string): string {
  const map: Record<string, string> = {
    stopwords: "Обнаружена ненормативная лексика",
    too_many_links: "Слишком много ссылок",
    blacklisted_link: "Запрещённая ссылка",
    regex_match: "Обнаружено запрещённое выражение",
    newbie_premod: "Премодерация нового пользователя",
    ad_too_many_links: "Подозрение на рекламу: много ссылок",
    ad_external_links: "Подозрение на рекламу: внешние ссылки",
    ai_toxic: "Обнаружен токсичный контент",
    ai_insult: "Обнаружены оскорбления",
    ai_hate: "Обнаружен язык ненависти",
    ai_threat: "Обнаружены угрозы",
    ai_spam: "Обнаружен спам",
    ai_low_quality: "Низкое качество контента",
  };
  if (flag.startsWith("ad_ai_")) return "Обнаружена реклама";
  if (flag.startsWith("ai_")) return map[flag] || "Нарушение правил (AI-проверка)";
  return map[flag] || "Нарушение правил форума";
}

export function jsonResponse(data: any, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
