import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SITE_URL = "https://aiplanetsound.lovable.app";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Fetch all visible topics (limited to 5000 for performance)
    const { data: topics, error: topicsError } = await supabase
      .from("forum_topics")
      .select("id, updated_at, title")
      .eq("is_hidden", false)
      .order("updated_at", { ascending: false })
      .limit(5000);

    if (topicsError) {
      console.error("Error fetching topics:", topicsError);
      throw topicsError;
    }

    // Fetch categories
    const { data: categories, error: catsError } = await supabase
      .from("forum_categories")
      .select("slug, updated_at")
      .eq("is_active", true);

    if (catsError) {
      console.error("Error fetching categories:", catsError);
      throw catsError;
    }

    // Fetch tags
    const { data: tags, error: tagsError } = await supabase
      .from("forum_tags")
      .select("name")
      .gt("usage_count", 0);

    if (tagsError) {
      console.error("Error fetching tags:", tagsError);
    }

    // Build XML sitemap
    let xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>${SITE_URL}/forum</loc>
    <changefreq>hourly</changefreq>
    <priority>0.8</priority>
  </url>
  <url>
    <loc>${SITE_URL}/forum/tags</loc>
    <changefreq>daily</changefreq>
    <priority>0.5</priority>
  </url>`;

    // Categories
    for (const cat of categories || []) {
      xml += `
  <url>
    <loc>${SITE_URL}/forum/c/${cat.slug}</loc>
    <lastmod>${new Date(cat.updated_at).toISOString()}</lastmod>
    <changefreq>daily</changefreq>
    <priority>0.7</priority>
  </url>`;
    }

    // Topics
    for (const topic of topics || []) {
      xml += `
  <url>
    <loc>${SITE_URL}/forum/t/${topic.id}</loc>
    <lastmod>${new Date(topic.updated_at).toISOString()}</lastmod>
    <changefreq>weekly</changefreq>
    <priority>0.6</priority>
  </url>`;
    }

    // Tags
    for (const tag of tags || []) {
      xml += `
  <url>
    <loc>${SITE_URL}/forum/tag/${encodeURIComponent(tag.name)}</loc>
    <changefreq>weekly</changefreq>
    <priority>0.4</priority>
  </url>`;
    }

    xml += `
</urlset>`;

    console.log(`[forum-sitemap] Generated sitemap with ${(categories?.length || 0)} categories, ${(topics?.length || 0)} topics, ${(tags?.length || 0)} tags`);

    return new Response(xml, {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/xml; charset=utf-8",
        "Cache-Control": "public, max-age=3600",
      },
    });
  } catch (error) {
    console.error("[forum-sitemap] Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
