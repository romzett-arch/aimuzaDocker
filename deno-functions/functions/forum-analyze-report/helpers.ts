import { corsHeaders } from "./constants.ts";

export function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function getCategoryLabel(category: string): string {
  const labels: Record<string, string> = {
    toxicity: "Токсичность / Оскорбления",
    spam: "Спам / Реклама",
    threats: "Угрозы / Буллинг",
    nsfw: "NSFW-контент",
    fraud: "Мошенничество",
    offtopic: "Оффтопик",
    copyright: "Нарушение авторских прав",
    none: "Нарушение не обнаружено",
  };
  return labels[category] || category;
}
