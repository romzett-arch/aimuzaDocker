import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SITE_URL = "https://aimuza.ru";

function urlEntry(loc: string, lastmod?: string, changefreq?: string, priority?: number): string {
  let entry = `  <url>\n    <loc>${loc}</loc>`;
  if (lastmod) entry += `\n    <lastmod>${lastmod}</lastmod>`;
  if (changefreq) entry += `\n    <changefreq>${changefreq}</changefreq>`;
  if (priority !== undefined) entry += `\n    <priority>${priority}</priority>`;
  entry += `\n  </url>`;
  return entry;
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
    let type = url.searchParams.get("type");
    if (!type && url.pathname) {
      if (url.pathname.includes("sitemap-pages")) type = "pages";
      else if (url.pathname.includes("sitemap-tracks")) type = "tracks";
      else if (url.pathname.includes("sitemap-artists")) type = "artists";
      else if (url.pathname.includes("sitemap-forum")) type = "forum";
      else if (url.pathname.includes("sitemap-contests")) type = "contests";
    }
    type = type || "index";

    if (type === "index") {
      const indexXml = `<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap>
    <loc>${SITE_URL}/sitemap-pages.xml</loc>
    <lastmod>${new Date().toISOString()}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE_URL}/sitemap-tracks.xml</loc>
    <lastmod>${new Date().toISOString()}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE_URL}/sitemap-artists.xml</loc>
    <lastmod>${new Date().toISOString()}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE_URL}/sitemap-forum.xml</loc>
    <lastmod>${new Date().toISOString()}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE_URL}/sitemap-contests.xml</loc>
    <lastmod>${new Date().toISOString()}</lastmod>
  </sitemap>
</sitemapindex>`;
      return new Response(indexXml, {
        headers: { ...corsHeaders, "Content-Type": "application/xml; charset=utf-8", "Cache-Control": "public, max-age=3600" },
      });
    }

    let urls: string[] = [];

    if (type === "pages") {
      const staticPages = [
        { path: "/", priority: 1, changefreq: "hourly" },
        { path: "/catalog", priority: 0.9, changefreq: "daily" },
        { path: "/feed", priority: 0.9, changefreq: "hourly" },
        { path: "/voting", priority: 0.9, changefreq: "daily" },
        { path: "/contests", priority: 0.8, changefreq: "daily" },
        { path: "/gallery", priority: 0.7, changefreq: "daily" },
        { path: "/playlists", priority: 0.7, changefreq: "daily" },
        { path: "/support", priority: 0.6, changefreq: "weekly" },
        { path: "/forum", priority: 0.8, changefreq: "hourly" },
        { path: "/radio", priority: 0.8, changefreq: "daily" },
      ];
      urls = staticPages.map(
        (p) => urlEntry(`${SITE_URL}${p.path}`, new Date().toISOString(), p.changefreq, p.priority)
      );
    } else if (type === "tracks") {
      const { data: tracks } = await supabase
        .from("tracks")
        .select("slug, id, updated_at")
        .eq("is_public", true)
        .limit(10000);
      for (const t of tracks || []) {
        const path = t.slug ? `/track/${t.slug}` : `/track/${t.id}`;
        urls.push(urlEntry(`${SITE_URL}${path}`, new Date(t.updated_at).toISOString(), "weekly", 0.7));
      }
    } else if (type === "artists") {
      const { data: profiles } = await supabase
        .from("profiles")
        .select("slug, user_id, updated_at")
        .not("username", "is", null)
        .limit(5000);
      for (const p of profiles || []) {
        const path = p.slug ? `/artist/${p.slug}` : `/profile/${p.user_id}`;
        urls.push(urlEntry(`${SITE_URL}${path}`, new Date(p.updated_at).toISOString(), "weekly", 0.6));
      }
    } else if (type === "forum") {
      urls.push(urlEntry(`${SITE_URL}/forum`, new Date().toISOString(), "hourly", 0.8));
      urls.push(urlEntry(`${SITE_URL}/forum/tags`, new Date().toISOString(), "daily", 0.5));
      const { data: categories } = await supabase.from("forum_categories").select("slug, updated_at").eq("is_active", true);
      for (const c of categories || []) {
        urls.push(urlEntry(`${SITE_URL}/forum/c/${c.slug}`, new Date(c.updated_at).toISOString(), "daily", 0.7));
      }
      const { data: topics } = await supabase
        .from("forum_topics")
        .select("id, updated_at")
        .eq("is_hidden", false)
        .order("updated_at", { ascending: false })
        .limit(5000);
      for (const t of topics || []) {
        urls.push(urlEntry(`${SITE_URL}/forum/t/${t.id}`, new Date(t.updated_at).toISOString(), "weekly", 0.6));
      }
    } else if (type === "contests") {
      const { data: contests } = await supabase.from("contests").select("id, updated_at").limit(500);
      for (const c of contests || []) {
        urls.push(urlEntry(`${SITE_URL}/contests/${c.id}`, new Date(c.updated_at).toISOString(), "weekly", 0.7));
      }
    }

    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.join("\n")}
</urlset>`;

    return new Response(xml, {
      headers: { ...corsHeaders, "Content-Type": "application/xml; charset=utf-8", "Cache-Control": "public, max-age=3600" },
    });
  } catch (error) {
    console.error("[sitemap-generator] Error:", error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
