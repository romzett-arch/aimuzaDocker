export type Mode =
  | "spell_check"
  | "expand_topic"
  | "expand_to_topic"
  | "expand_reply"
  | "summarize_thread"
  | "suggest_arguments"
  | "auto_tags";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

export const AGENT_ACCESS_ID =
  Deno.env.get("TIMEWEB_AGENT_ID") || "df42cd86-5e91-459e-a95a-a7befb625292";

export const SERVICE_NAMES: Record<Mode, string> = {
  spell_check: "forum_spell_check",
  expand_topic: "forum_expand_topic",
  expand_to_topic: "forum_expand_topic",
  expand_reply: "forum_expand_reply",
  summarize_thread: "forum_summarize_thread",
  suggest_arguments: "forum_suggest_arguments",
  auto_tags: "forum_auto_tags",
};

export const DEFAULT_PRICES: Record<Mode, number> = {
  spell_check: 3,
  expand_topic: 5,
  expand_to_topic: 5,
  expand_reply: 5,
  summarize_thread: 3,
  suggest_arguments: 4,
  auto_tags: 0,
};

export const MESSAGES: Record<Mode, string> = {
  spell_check: "Текст проверен!",
  expand_topic: "Тезисы развёрнуты!",
  expand_to_topic: "Тема сгенерирована!",
  expand_reply: "Ответ развёрнут!",
  summarize_thread: "Резюме готово!",
  suggest_arguments: "Аргументы готовы!",
  auto_tags: "Теги сгенерированы!",
};

export const TAG_COLORS = [
  "#6366f1", "#10b981", "#f59e0b", "#ec4899", "#ef4444",
  "#8b5cf6", "#06b6d4", "#a855f7", "#14b8a6", "#f97316",
  "#84cc16", "#0ea5e9", "#d946ef", "#22c55e", "#e11d48",
  "#7c3aed", "#0891b2", "#c026d3", "#16a34a", "#ea580c",
];
