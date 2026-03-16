import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  SITE_URL,
  getStaticSeoPageByPath,
  logBotVisit,
} from "../../shared/seo.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface SeoMetaRow {
  title: string | null;
  description: string | null;
  og_title: string | null;
  og_description: string | null;
  og_image_url: string | null;
  canonical_url: string | null;
  robots_directive: string | null;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function toAbsoluteUrl(value: string | null | undefined): string | null {
  if (!value) return null;
  if (value.startsWith("http://") || value.startsWith("https://")) return value;
  return `${SITE_URL}${value.startsWith("/") ? value : `/${value}`}`;
}

async function fetchSeoMetadata(
  supabase: ReturnType<typeof createClient>,
  params: { entityType: string; entityId?: string; pageKey?: string },
): Promise<SeoMetaRow | null> {
  let query = supabase
    .from("seo_metadata")
    .select("title, description, og_title, og_description, og_image_url, canonical_url, robots_directive")
    .eq("entity_type", params.entityType)
    .eq("is_active", true);

  if (params.entityId) {
    query = query.eq("entity_id", params.entityId);
  } else if (params.pageKey) {
    query = query.eq("page_key", params.pageKey);
  } else {
    return null;
  }

  const { data } = await query.maybeSingle();
  return (data as SeoMetaRow | null) ?? null;
}

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const url = new URL(req.url);
    const rawPath = url.searchParams.get("url") || url.searchParams.get("path") || "/";
    const normalizedPath = rawPath.startsWith("http")
      ? new URL(rawPath).pathname
      : rawPath;

    let title = "AIMUZA: AI-музыка, сообщество артистов и дистрибуция";
    let description = "Создавайте AI-музыку, развивайте профиль артиста, общайтесь с сообществом и готовьте релизы к дистрибуции в экосистеме AIMUZA.";
    let image = `${SITE_URL}/pwa-512x512.png`;
    let type = "website";
    let robots = "index, follow";
    let canonicalUrl = `${SITE_URL}${normalizedPath}`;

    const staticPage = getStaticSeoPageByPath(normalizedPath);
    if (staticPage) {
      const meta = await fetchSeoMetadata(supabase, {
        entityType: "page",
        pageKey: staticPage.pageKey,
      });
      title = meta?.og_title || meta?.title || staticPage.title;
      description = meta?.og_description || meta?.description || staticPage.description;
      image = toAbsoluteUrl(meta?.og_image_url) || image;
      canonicalUrl = toAbsoluteUrl(meta?.canonical_url) || canonicalUrl;
      robots = meta?.robots_directive || robots;
    }

    const matchTrack = normalizedPath.match(/^\/track\/([^/?#]+)/);
    const matchProfile = normalizedPath.match(/^\/profile\/([^/?#]+)/);
    const matchArtist = normalizedPath.match(/^\/artist\/([^/?#]+)/);
    const matchForumTopic = normalizedPath.match(/^\/forum\/t\/([^/?#]+)/);
    const matchContest = normalizedPath.match(/^\/contests\/([^/?#]+)/);

    if (matchTrack) {
      const slugOrId = matchTrack[1];
      const isUuid = /^[0-9a-f-]{36}$/i.test(slugOrId);
      const { data: track } = await supabase
        .from("tracks")
        .select("id, slug, title, description, cover_url, duration, user_id, genre_id")
        .or(isUuid ? `id.eq.${slugOrId}` : `slug.eq.${slugOrId}`)
        .eq("is_public", true)
        .maybeSingle();

      if (track) {
        const { data: profile } = await supabase
          .from("profiles")
          .select("username")
          .eq("user_id", track.user_id)
          .maybeSingle();
        const artist = profile?.username || "Артист AIMUZA";
        const meta = await fetchSeoMetadata(supabase, {
          entityType: "track",
          entityId: track.id,
        });
        title = meta?.og_title || meta?.title || `${track.title} — слушать онлайн | ${artist}`;
        description = meta?.og_description || meta?.description || track.description || `Слушайте трек "${track.title}" от ${artist} на AIMUZA.`;
        image = toAbsoluteUrl(meta?.og_image_url) || toAbsoluteUrl(track.cover_url) || image;
        canonicalUrl = toAbsoluteUrl(meta?.canonical_url) || `${SITE_URL}/track/${track.slug || track.id}`;
        robots = meta?.robots_directive || robots;
        type = "music.song";
      }
    } else if (matchProfile || matchArtist) {
      const slugOrId = (matchArtist || matchProfile)![1];
      const { data: profile } = await supabase
        .from("profiles")
        .select("user_id, username, slug, avatar_url, bio")
        .or(`user_id.eq.${slugOrId},slug.eq.${slugOrId}`)
        .maybeSingle();

      if (profile) {
        const { count } = await supabase
          .from("tracks")
          .select("id", { count: "exact", head: true })
          .eq("user_id", profile.user_id)
          .eq("is_public", true);
        const meta = await fetchSeoMetadata(supabase, {
          entityType: "profile",
          entityId: profile.user_id,
        });
        title = meta?.og_title || meta?.title || `${profile.username || "Артист"} — профиль артиста`;
        description = meta?.og_description || meta?.description || profile.bio || `Профиль артиста ${profile.username || "AIMUZA"}${count ? `. Публичных треков: ${count}.` : ""}`;
        image = toAbsoluteUrl(meta?.og_image_url) || toAbsoluteUrl(profile.avatar_url) || image;
        canonicalUrl = toAbsoluteUrl(meta?.canonical_url) || `${SITE_URL}/${profile.slug ? `artist/${profile.slug}` : `profile/${profile.user_id}`}`;
        robots = meta?.robots_directive || robots;
        type = "profile";
      }
    } else if (matchForumTopic) {
      const topicId = matchForumTopic[1];
      const { data: topic } = await supabase
        .from("forum_topics")
        .select("id, title, content, content_html")
        .eq("id", topicId)
        .eq("is_hidden", false)
        .maybeSingle();

      if (topic) {
        const excerpt = (topic.content_html || topic.content || "").replace(/<[^>]*>/g, "").slice(0, 180);
        const meta = await fetchSeoMetadata(supabase, {
          entityType: "forum_topic",
          entityId: topic.id,
        });
        title = meta?.og_title || meta?.title || `${topic.title} | Форум AIMUZA`;
        description = meta?.og_description || meta?.description || excerpt || `Обсуждение на форуме AIMUZA: ${topic.title}`;
        image = toAbsoluteUrl(meta?.og_image_url) || image;
        canonicalUrl = toAbsoluteUrl(meta?.canonical_url) || `${SITE_URL}/forum/t/${topic.id}`;
        robots = meta?.robots_directive || robots;
        type = "article";
      }
    } else if (matchContest) {
      const contestId = matchContest[1];
      const { data: contest } = await supabase
        .from("contests")
        .select("id, title, description, cover_url, prize_amount")
        .eq("id", contestId)
        .maybeSingle();

      if (contest) {
        const meta = await fetchSeoMetadata(supabase, {
          entityType: "contest",
          entityId: contest.id,
        });
        title = meta?.og_title || meta?.title || `${contest.title} | Конкурс AIMUZA`;
        description = meta?.og_description || meta?.description || contest.description || `Музыкальный конкурс AIMUZA: ${contest.title}${contest.prize_amount ? `. Призовой фонд ${contest.prize_amount} ₽.` : ""}`;
        image = toAbsoluteUrl(meta?.og_image_url) || toAbsoluteUrl(contest.cover_url) || image;
        canonicalUrl = toAbsoluteUrl(meta?.canonical_url) || `${SITE_URL}/contests/${contest.id}`;
        robots = meta?.robots_directive || robots;
        type = "article";
      }
    }

    const fullUrl = rawPath.startsWith("http") ? rawPath : `${SITE_URL}${normalizedPath}`;
    const html = `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>${escapeHtml(title)}</title>
  <meta name="description" content="${escapeHtml(description)}">
  <meta name="robots" content="${escapeHtml(robots)}">
  <link rel="canonical" href="${escapeHtml(canonicalUrl)}">
  <meta property="og:type" content="${escapeHtml(type)}">
  <meta property="og:url" content="${escapeHtml(fullUrl)}">
  <meta property="og:title" content="${escapeHtml(title)}">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:image" content="${escapeHtml(image)}">
  <meta property="og:site_name" content="AIMUZA">
  <meta property="og:locale" content="ru_RU">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${escapeHtml(title)}">
  <meta name="twitter:description" content="${escapeHtml(description)}">
  <meta name="twitter:image" content="${escapeHtml(image)}">
  <meta http-equiv="refresh" content="0;url=${escapeHtml(fullUrl)}">
</head>
<body><p>Redirecting...</p></body>
</html>`;

    const response = new Response(html, {
      headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=3600" },
    });
    await logBotVisit(supabase, req, "og-renderer", response.status, normalizedPath);
    return response;
  } catch (error) {
    console.error("[og-renderer] Error:", error);
    return new Response("<!DOCTYPE html><html><body>Error</body></html>", {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "text/html" },
    });
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
