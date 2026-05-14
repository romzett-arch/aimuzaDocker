import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SITE_URL = "https://aimuza.ru";

const DEFAULT_TITLE = "AIMUZA — социальная сеть AI-музыкантов и релизы через НОТА-ФЕЯ";
const DEFAULT_DESCRIPTION =
  "AIMUZA — социальная платформа для AI-музыкантов: публикуйте треки, развивайте профиль артиста, находите слушателей и выпускайте релизы через лейбл НОТА-ФЕЯ.";

const STATIC_PAGE_KEYS: Record<string, string> = {
  "/": "home",
  "/catalog": "catalog",
  "/feed": "feed",
  "/users": "users",
  "/playlists": "playlists",
  "/forum": "forum",
  "/radio": "radio",
  "/pricing": "pricing",
  "/terms": "terms",
  "/offer": "offer",
  "/privacy": "privacy",
  "/requisites": "requisites",
  "/distribution-requirements": "distribution-requirements",
  "/audit-policy": "audit-policy",
};

const STATIC_PAGE_FALLBACKS: Record<string, { title: string; description: string }> = {
  home: {
    title: "AIMUZA — социальная сеть AI-музыкантов",
    description: "Публикуйте треки, находите слушателей и выпускайте релизы через музыкальный лейбл НОТА-ФЕЯ.",
  },
  catalog: {
    title: "Каталог треков и артистов AIMUZA",
    description: "Слушайте треки AI-музыкантов, открывайте новых артистов, жанры и релизы в каталоге AIMUZA.",
  },
  feed: {
    title: "Музыкальная лента AIMUZA",
    description: "Следите за новыми треками, активностью артистов, подборками и релизами сообщества AIMUZA.",
  },
  users: {
    title: "AI-музыканты и артисты AIMUZA",
    description: "Изучайте профили AI-музыкантов, находите авторов, слушателей и новые музыкальные коллаборации.",
  },
  playlists: {
    title: "Плейлисты AIMUZA",
    description: "Слушайте подборки треков AIMUZA, открывайте новые жанры и сохраняйте музыкальные коллекции сообщества.",
  },
  forum: {
    title: "Форум AI-музыкантов AIMUZA",
    description: "Обсуждайте релизы, продакшн, AI-инструменты и дистрибуцию с музыкальным сообществом AIMUZA.",
  },
  radio: {
    title: "Онлайн-радио AIMUZA",
    description: "Слушайте радио AIMUZA с треками артистов сообщества, новыми релизами и музыкальными открытиями.",
  },
  pricing: {
    title: "Тарифы AIMUZA для артистов",
    description: "Тарифы для публикации треков, AI-инструментов, депонирования, продвижения и дистрибуции релизов.",
  },
  terms: {
    title: "Пользовательское соглашение AIMUZA",
    description: "Официальное пользовательское соглашение сервиса AIMUZA для артистов и пользователей платформы.",
  },
  offer: {
    title: "Публичная оферта AIMUZA",
    description: "Публичная оферта AIMUZA с условиями оказания услуг, публикации контента и платных функций платформы.",
  },
  privacy: {
    title: "Политика конфиденциальности AIMUZA",
    description: "Политика конфиденциальности AIMUZA: обработка персональных данных, безопасность и права пользователей.",
  },
  requisites: {
    title: "Реквизиты AIMUZA",
    description: "Юридические и платёжные реквизиты AIMUZA и музыкального лейбла НОТА-ФЕЯ.",
  },
  "distribution-requirements": {
    title: "Требования к релизам для дистрибуции",
    description: "Проверьте требования AIMUZA к трекам, метаданным и материалам перед отправкой релиза на дистрибуцию.",
  },
  "audit-policy": {
    title: "Политика модерации и аудита AIMUZA",
    description: "Как AIMUZA проверяет релизы, контент и соблюдение правил перед публикацией и дистрибуцией.",
  },
};

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function normalizeOgPath(rawPath: string | null): string {
  const value = (rawPath || "/").trim();
  if (!value.startsWith("/")) {
    return "/";
  }
  return value;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const url = new URL(req.url);
    const path = normalizeOgPath(url.searchParams.get("url") || url.searchParams.get("path"));

    let title = DEFAULT_TITLE;
    let description = DEFAULT_DESCRIPTION;
    let image = `${SITE_URL}/pwa-512x512.png`;
    let type = "website";

    const matchTrack = path.match(/^\/track\/([^\/\?]+)/);
    const matchProfile = path.match(/^\/profile\/([^\/\?]+)/);
    const matchArtist = path.match(/^\/artist\/([^\/\?]+)/);
    const matchForumTopic = path.match(/^\/forum\/t\/([^\/\?]+)/);

    const staticPageKey = STATIC_PAGE_KEYS[path.replace(/\/$/, "") || "/"];

    if (staticPageKey) {
      const fallback = STATIC_PAGE_FALLBACKS[staticPageKey];
      if (fallback) {
        title = fallback.title;
        description = fallback.description;
      }

      const { data: meta } = await supabase
        .from("seo_metadata")
        .select("title, description, og_title, og_description, og_image_url")
        .eq("entity_type", "page")
        .eq("page_key", staticPageKey)
        .eq("is_active", true)
        .maybeSingle();

      if (meta) {
        title = meta.og_title || meta.title || title;
        description = meta.og_description || meta.description || description;
        if (meta.og_image_url) image = meta.og_image_url.startsWith("http") ? meta.og_image_url : `${SITE_URL}${meta.og_image_url}`;
      }
    } else if (matchTrack) {
      const slugOrId = matchTrack[1];
      const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(slugOrId);
      const { data: track } = await supabase
        .from("tracks")
        .select("id, title, description, cover_url, duration, user_id, genre_id")
        .or(isUuid ? `id.eq.${slugOrId}` : `slug.eq.${slugOrId}`)
        .eq("is_public", true)
        .maybeSingle();
      if (track) {
        const { data: prof } = await supabase.from("profiles").select("username").eq("user_id", track.user_id).maybeSingle();
        const artist = prof?.username || "AIMUZA";
        title = `${track.title} — ${artist} | AIMUZA`;
        description = track.description || `Слушайте "${track.title}" от ${artist} на AIMUZA`;
        if (track.cover_url) image = track.cover_url!.startsWith("http") ? track.cover_url! : `${SITE_URL}${track.cover_url}`;
        type = "music.song";
      }
    } else if (matchProfile || matchArtist) {
      const slugOrId = (matchProfile || matchArtist)![1];
      const { data: profile } = await supabase
        .from("profiles")
        .select("username, avatar_url, bio")
        .or(`user_id.eq.${slugOrId},slug.eq.${slugOrId}`)
        .maybeSingle();
      if (profile) {
        title = `${profile.username || "Артист"} | AIMUZA`;
        description = profile.bio || `Профиль ${profile.username || "артиста"} на AIMUZA`;
        if (profile.avatar_url) image = profile.avatar_url.startsWith("http") ? profile.avatar_url : `${SITE_URL}${profile.avatar_url}`;
        type = "profile";
      }
    } else if (matchForumTopic) {
      const topicId = matchForumTopic[1];
      const { data: topic } = await supabase
        .from("forum_topics")
        .select("title, content")
        .eq("id", topicId)
        .eq("is_hidden", false)
        .maybeSingle();
      if (topic) {
        title = `${topic.title} | Форум AIMUZA`;
        const excerpt = (topic.content || "").replace(/<[^>]*>/g, "").slice(0, 160);
        description = excerpt || `Обсуждение: ${topic.title}`;
        type = "article";
      }
    }

    const fullUrl = `${SITE_URL}${path}`;
    const safeTitle = escapeHtml(title);
    const safeDescription = escapeHtml(description);
    const safeImage = escapeHtml(image);
    const safeFullUrl = escapeHtml(fullUrl);
    const html = `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>${safeTitle}</title>
  <meta name="description" content="${safeDescription}">
  <meta property="og:type" content="${type}">
  <meta property="og:url" content="${safeFullUrl}">
  <meta property="og:title" content="${safeTitle}">
  <meta property="og:description" content="${safeDescription}">
  <meta property="og:image" content="${safeImage}">
  <meta property="og:site_name" content="AIMUZA">
  <meta property="og:locale" content="ru_RU">
  <link rel="canonical" href="${safeFullUrl}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${safeTitle}">
  <meta name="twitter:description" content="${safeDescription}">
  <meta name="twitter:image" content="${safeImage}">
</head>
<body>
  <main>
    <h1>${safeTitle}</h1>
    <p>${safeDescription}</p>
    <p><a href="${safeFullUrl}">Открыть страницу на AIMUZA</a></p>
  </main>
</body>
</html>`;

    return new Response(html, {
      headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=3600" },
    });
  } catch (error) {
    console.error("[og-renderer] Error:", error);
    return new Response("<!DOCTYPE html><html><body>Error</body></html>", {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "text/html" },
    });
  }
});
