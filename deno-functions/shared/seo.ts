import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

export const SITE_URL = "https://aimuza.ru";

export interface StaticSeoPageDefinition {
  pageKey: string;
  path: string;
  title: string;
  description: string;
  priority: number;
  changefreq: string;
  indexable: boolean;
  pageType: "landing" | "catalog" | "feed" | "community" | "distribution" | "legal" | "radio";
  intent: string;
}

export const STATIC_SEO_PAGES: StaticSeoPageDefinition[] = [
  {
    pageKey: "home",
    path: "/",
    title: "AIMUZA: AI-музыка, сообщество артистов и дистрибуция",
    description: "Создавайте AI-музыку, развивайте профиль артиста, общайтесь с сообществом и отправляйте релизы на дистрибуцию в одной экосистеме.",
    priority: 1,
    changefreq: "daily",
    indexable: true,
    pageType: "landing",
    intent: "Главный вход в экосистему: AI-инструменты, сообщество музыкантов, публикация и дистрибуция.",
  },
  {
    pageKey: "catalog",
    path: "/catalog",
    title: "Каталог треков и артистов AIMUZA",
    description: "Слушайте треки артистов AIMUZA, открывайте новые релизы, жанры и авторов в каталоге музыкальной платформы.",
    priority: 0.9,
    changefreq: "daily",
    indexable: true,
    pageType: "catalog",
    intent: "Каталог для поиска и прослушивания треков, артистов и релизов.",
  },
  {
    pageKey: "feed",
    path: "/feed",
    title: "Музыкальная лента AIMUZA",
    description: "Следите за новыми треками, активностью артистов и подборками сообщества AIMUZA в живой музыкальной ленте.",
    priority: 0.9,
    changefreq: "hourly",
    indexable: true,
    pageType: "feed",
    intent: "Живая лента новых треков, активности артистов и рекомендаций.",
  },
  {
    pageKey: "voting",
    path: "/voting",
    title: "Голосование за треки на дистрибуцию",
    description: "Слушайте треки, голосуйте за релизы и помогайте артистам AIMUZA пройти отбор перед отправкой на дистрибуцию.",
    priority: 0.85,
    changefreq: "daily",
    indexable: true,
    pageType: "distribution",
    intent: "Страница голосования сообщества за треки перед дистрибуцией.",
  },
  {
    pageKey: "contests",
    path: "/contests",
    title: "Конкурсы артистов и AI-музыки AIMUZA",
    description: "Участвуйте в музыкальных конкурсах AIMUZA, получайте внимание сообщества, награды и новые возможности для артистического роста.",
    priority: 0.85,
    changefreq: "daily",
    indexable: true,
    pageType: "community",
    intent: "Конкурсы, лиги и активности для артистов и сообщества.",
  },
  {
    pageKey: "users",
    path: "/users",
    title: "Артисты и пользователи AIMUZA",
    description: "Изучайте профили артистов и участников сообщества AIMUZA, находите авторов, единомышленников и новые коллаборации.",
    priority: 0.75,
    changefreq: "daily",
    indexable: true,
    pageType: "community",
    intent: "Публичная витрина участников сообщества и артистов.",
  },
  {
    pageKey: "playlists",
    path: "/playlists",
    title: "Плейлисты AIMUZA",
    description: "Слушайте подборки треков AIMUZA, открывайте новые жанры и сохраняйте музыкальные коллекции сообщества.",
    priority: 0.65,
    changefreq: "daily",
    indexable: true,
    pageType: "catalog",
    intent: "Публичные музыкальные подборки и плейлисты.",
  },
  {
    pageKey: "forum",
    path: "/forum",
    title: "Форум музыкантов и AI-авторов AIMUZA",
    description: "Обсуждайте музыку, AI-инструменты, продакшн и дистрибуцию на форуме сообщества AIMUZA.",
    priority: 0.8,
    changefreq: "hourly",
    indexable: true,
    pageType: "community",
    intent: "Форум сообщества: обсуждения, обмен опытом, помощь и идеи.",
  },
  {
    pageKey: "radio",
    path: "/radio",
    title: "Онлайн-радио AIMUZA",
    description: "Слушайте радио AIMUZA с треками артистов сообщества, новыми релизами и музыкальными открытиями.",
    priority: 0.7,
    changefreq: "daily",
    indexable: true,
    pageType: "radio",
    intent: "Потоковое радио с треками артистов и активностью сообщества.",
  },
  {
    pageKey: "pricing",
    path: "/pricing",
    title: "Тарифы и цены AIMUZA",
    description: "Изучите тарифы, стоимость AI-генерации, дополнительных услуг и возможностей платформы AIMUZA для артистов.",
    priority: 0.6,
    changefreq: "weekly",
    indexable: true,
    pageType: "legal",
    intent: "Коммерческая страница с тарифами, ценами и условиями услуг.",
  },
  {
    pageKey: "terms",
    path: "/terms",
    title: "Пользовательское соглашение AIMUZA",
    description: "Официальное пользовательское соглашение сервиса AIMUZA для артистов и пользователей платформы.",
    priority: 0.35,
    changefreq: "monthly",
    indexable: true,
    pageType: "legal",
    intent: "Юридическая страница с правилами использования сервиса.",
  },
  {
    pageKey: "offer",
    path: "/offer",
    title: "Публичная оферта AIMUZA",
    description: "Публичная оферта AIMUZA с условиями оказания услуг, публикации контента и использования платных функций платформы.",
    priority: 0.35,
    changefreq: "monthly",
    indexable: true,
    pageType: "legal",
    intent: "Юридическая страница с условиями оферты и оказания услуг.",
  },
  {
    pageKey: "privacy",
    path: "/privacy",
    title: "Политика конфиденциальности AIMUZA",
    description: "Политика конфиденциальности AIMUZA: обработка персональных данных, безопасность и права пользователей.",
    priority: 0.35,
    changefreq: "monthly",
    indexable: true,
    pageType: "legal",
    intent: "Юридическая страница с политикой обработки данных.",
  },
  {
    pageKey: "requisites",
    path: "/requisites",
    title: "Реквизиты AIMUZA",
    description: "Юридические и платёжные реквизиты AIMUZA и музыкального лейбла Нота-Фея.",
    priority: 0.3,
    changefreq: "monthly",
    indexable: true,
    pageType: "legal",
    intent: "Реквизиты компании и юридическая информация.",
  },
  {
    pageKey: "distribution-requirements",
    path: "/distribution-requirements",
    title: "Требования к релизам для дистрибуции",
    description: "Проверьте требования AIMUZA к трекам, метаданным и материалам перед отправкой релиза на дистрибуцию.",
    priority: 0.55,
    changefreq: "weekly",
    indexable: true,
    pageType: "distribution",
    intent: "Инструкции и требования для релизов перед дистрибуцией.",
  },
  {
    pageKey: "audit-policy",
    path: "/audit-policy",
    title: "Политика модерации и аудита AIMUZA",
    description: "Узнайте, как AIMUZA проверяет релизы, контент и соблюдение правил перед публикацией и дистрибуцией.",
    priority: 0.45,
    changefreq: "monthly",
    indexable: true,
    pageType: "legal",
    intent: "Правила модерации, проверки и аудита контента.",
  },
];

const BOT_PATTERNS: Array<{ family: string; pattern: RegExp }> = [
  { family: "googlebot", pattern: /googlebot/i },
  { family: "googlebot-image", pattern: /googlebot-image/i },
  { family: "bingbot", pattern: /bingbot/i },
  { family: "yandexbot", pattern: /yandex(bot|images|mobilebot)/i },
  { family: "duckduckbot", pattern: /duckduckbot/i },
  { family: "baiduspider", pattern: /baiduspider/i },
  { family: "slurp", pattern: /slurp/i },
  { family: "facebookexternalhit", pattern: /facebookexternalhit/i },
  { family: "twitterbot", pattern: /twitterbot/i },
  { family: "linkedinbot", pattern: /linkedinbot/i },
  { family: "telegrambot", pattern: /telegrambot/i },
  { family: "whatsapp", pattern: /whatsapp/i },
  { family: "slackbot", pattern: /slackbot/i },
  { family: "discordbot", pattern: /discordbot/i },
  { family: "gptbot", pattern: /gptbot/i },
  { family: "chatgpt-user", pattern: /chatgpt-user/i },
  { family: "claude-web", pattern: /claude-web/i },
  { family: "anthropic-ai", pattern: /anthropic-ai/i },
  { family: "ccbot", pattern: /ccbot/i },
  { family: "perplexitybot", pattern: /perplexitybot/i },
  { family: "bytespider", pattern: /bytespider/i },
  { family: "google-extended", pattern: /google-extended/i },
];

export function getStaticSeoPage(pageKey: string): StaticSeoPageDefinition | undefined {
  return STATIC_SEO_PAGES.find((page) => page.pageKey === pageKey);
}

export function getStaticSeoPageByPath(pathname: string): StaticSeoPageDefinition | undefined {
  return STATIC_SEO_PAGES.find((page) => page.path === pathname);
}

export function normalizeBotFamily(userAgent: string | null): string | null {
  if (!userAgent) return null;
  const match = BOT_PATTERNS.find((entry) => entry.pattern.test(userAgent));
  return match?.family ?? null;
}

export function isKnownBot(userAgent: string | null): boolean {
  return normalizeBotFamily(userAgent) !== null;
}

export function getClientIp(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) {
    return forwarded.split(",")[0]?.trim() || "";
  }

  return req.headers.get("x-real-ip")?.trim() || "";
}

export async function hashIp(ip: string): Promise<string | null> {
  if (!ip) return null;
  const bytes = new TextEncoder().encode(ip);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const hash = [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return hash.slice(0, 32);
}

export async function logBotVisit(
  supabase: SupabaseClient,
  req: Request,
  source: string,
  responseStatus: number,
  resolvedPath?: string,
): Promise<void> {
  try {
    const userAgent = req.headers.get("user-agent");
    const botFamily = normalizeBotFamily(userAgent);
    if (!botFamily) return;

    const url = new URL(req.url);
    const path = resolvedPath || url.pathname;
    const referer = req.headers.get("referer");
    const ipHash = await hashIp(getClientIp(req));

    await supabase.from("seo_bot_visits").insert({
      bot_family: botFamily,
      user_agent: userAgent,
      request_path: path,
      query_string: url.search || null,
      referer,
      response_status: responseStatus,
      source_layer: source,
      ip_hash: ipHash,
    });
  } catch (error) {
    console.error("[seo-log] Error:", error);
  }
}
