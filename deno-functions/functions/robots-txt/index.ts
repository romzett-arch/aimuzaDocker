import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SITE_URL = "https://aimuza.ru";

serve(async (req) => {
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
    txt += `Allow: /voting\n`;
    txt += `Disallow: /admin\n`;
    txt += `Disallow: /admin/\n`;
    txt += `Disallow: /messages\n`;
    txt += `Disallow: /my-tracks\n`;
    txt += `Disallow: /verify\n`;
    txt += `Disallow: /auth\n\n`;
    txt += `Host: ${SITE_URL}\n\n`;
    txt += `Sitemap: ${SITE_URL}/sitemap.xml\n`;

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

    return new Response(txt, {
      headers: { ...corsHeaders, "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "public, max-age=3600" },
    });
  } catch (error) {
    console.error("[robots-txt] Error:", error);
    return new Response("User-agent: *\nAllow: /", {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }
});
