import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { SITE_URL, logBotVisit } from "../../shared/seo.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const blockedAiBots = [
  "GPTBot",
  "ChatGPT-User",
  "CCBot",
  "anthropic-ai",
  "Claude-Web",
  "Google-Extended",
  "PerplexityBot",
  "Bytespider",
];

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { data: rules } = await supabase
      .from("seo_robots_rules")
      .select("user_agent, rule_type, path, crawl_delay")
      .eq("is_active", true)
      .order("sort_order")
      .order("user_agent");

    let txt = `# AIMUZA - Robots.txt\n# ${SITE_URL}\n\n`;
    txt += `User-agent: *\n`;
    txt += `Allow: /\n`;
    txt += `Allow: /catalog\n`;
    txt += `Allow: /feed\n`;
    txt += `Allow: /track/\n`;
    txt += `Allow: /profile/\n`;
    txt += `Allow: /artist/\n`;
    txt += `Allow: /contests\n`;
    txt += `Allow: /forum\n`;
    txt += `Allow: /forum/\n`;
    txt += `Allow: /voting\n`;
    txt += `Allow: /users\n`;
    txt += `Allow: /playlists\n`;
    txt += `Allow: /radio\n`;
    txt += `Allow: /pricing\n`;
    txt += `Allow: /terms\n`;
    txt += `Allow: /offer\n`;
    txt += `Allow: /privacy\n`;
    txt += `Allow: /requisites\n`;
    txt += `Allow: /distribution-requirements\n`;
    txt += `Allow: /audit-policy\n`;
    txt += `Disallow: /admin\n`;
    txt += `Disallow: /admin/\n`;
    txt += `Disallow: /gallery\n`;
    txt += `Disallow: /gallery/\n`;
    txt += `Disallow: /messages\n`;
    txt += `Disallow: /my-tracks\n`;
    txt += `Disallow: /support\n`;
    txt += `Disallow: /support/\n`;
    txt += `Disallow: /verify\n`;
    txt += `Disallow: /auth\n\n`;
    txt += `Disallow: /*?*\n\n`;
    txt += `Host: aimuza.ru\n\n`;
    txt += `Sitemap: ${SITE_URL}/sitemap.xml\n`;

    for (const bot of blockedAiBots) {
      txt += `\nUser-agent: ${bot}\n`;
      txt += `Disallow: /\n`;
    }

    if (rules?.length) {
      const byAgent = (rules as { user_agent: string; rule_type: string; path: string; crawl_delay?: number }[]).reduce(
        (acc, r) => {
          if (!acc[r.user_agent]) acc[r.user_agent] = [];
          acc[r.user_agent].push(r);
          return acc;
        },
        {} as Record<string, { rule_type: string; path: string; crawl_delay?: number }[]>
      );
      for (const [agent, items] of Object.entries(byAgent)) {
        txt += `\nUser-agent: ${agent}\n`;
        for (const item of items) {
          txt += `${item.rule_type === "allow" ? "Allow" : "Disallow"}: ${item.path}\n`;
          if (item.crawl_delay) txt += `Crawl-delay: ${item.crawl_delay}\n`;
        }
      }
    }

    const response = new Response(txt, {
      headers: { ...corsHeaders, "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "public, max-age=3600" },
    });
    await logBotVisit(supabase, req, "robots", response.status, "/robots.txt");
    return response;
  } catch (error) {
    console.error("[robots-txt] Error:", error);
    const fallback = new Response(`User-agent: *\nAllow: /\nSitemap: ${SITE_URL}/sitemap.xml\n`, {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
    return fallback;
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
