/**
 * D5: AI-таргетинг рекламы
 * DeepSeek для rule-based matching: профиль пользователя vs кампании
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};


serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const body = await req.json().catch(() => ({}));
    const { slot_key, user_id, device_type = "desktop" } = body;

    if (!slot_key?.trim()) {
      return new Response(
        JSON.stringify({ error: "slot_key required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: adsSetting } = await supabase
      .from("ad_settings")
      .select("value")
      .eq("key", "ads_enabled")
      .maybeSingle();
    if (adsSetting?.value === "false") {
      return new Response(
        JSON.stringify({ ad: null }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "ad_targeting")
      .maybeSingle();

    const config = setting?.value as { enabled?: boolean } | null;
    if (!config?.enabled) {
      return new Response(
        JSON.stringify({ ad: null, fallback: true }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: slot } = await supabase
      .from("ad_slots")
      .select("id")
      .eq("slot_key", slot_key)
      .eq("is_enabled", true)
      .maybeSingle();

    if (!slot?.id) {
      return new Response(
        JSON.stringify({ ad: null }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (user_id) {
      const { data: profile } = await supabase
        .from("profiles")
        .select("ad_free_until")
        .eq("user_id", user_id)
        .maybeSingle();

      if (profile?.ad_free_until && new Date(profile.ad_free_until) > new Date()) {
        return new Response(
          JSON.stringify({ ad: null }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { data: premiumPlans } = await supabase
        .from("ad_settings")
        .select("value")
        .eq("key", "premium_plans_no_ads")
        .maybeSingle();

      const planIds = premiumPlans?.value
        ? String(premiumPlans.value).split(",").map((s) => s.trim()).filter(Boolean)
        : [];
      if (planIds.length > 0) {
        const { data: sub } = await supabase
          .from("user_subscriptions")
          .select("id")
          .eq("user_id", user_id)
          .eq("status", "active")
          .in("plan_id", planIds)
          .maybeSingle();
        if (sub) {
          return new Response(
            JSON.stringify({ ad: null }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
      }
    }

    const { data: campaignSlots } = await supabase
      .from("ad_campaign_slots")
      .select("campaign_id, priority_override")
      .eq("slot_id", slot.id)
      .eq("is_active", true);

    if (!campaignSlots?.length) {
      return new Response(
        JSON.stringify({ ad: null }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const campaignIds = campaignSlots.map((cs) => cs.campaign_id);
    const now = new Date().toISOString();

    const { data: campaigns } = await supabase
      .from("ad_campaigns")
      .select("id, name, campaign_type, internal_type, internal_id, priority, budget_total, impressions_count")
      .in("id", campaignIds)
      .eq("status", "active")
      .or(`start_date.is.null,start_date.lte.${now}`)
      .or(`end_date.is.null,end_date.gt.${now}`);

    const { data: targetingRows } = await supabase
      .from("ad_targeting")
      .select("campaign_id, target_mobile, target_desktop")
      .in("campaign_id", campaigns?.map((c) => c.id) || []);

    const targetingMap = new Map(
      targetingRows?.map((t) => [t.campaign_id, t]) || []
    );

    const eligibleCampaigns = campaigns?.filter((c) => {
      if (c.budget_total && (c.impressions_count ?? 0) >= c.budget_total) return false;
      const t = targetingMap.get(c.id);
      if (!t) return true;
      if (device_type === "mobile" && t.target_mobile === false) return false;
      if (device_type === "desktop" && t.target_desktop === false) return false;
      return true;
    }) || [];

    if (!eligibleCampaigns.length) {
      return new Response(
        JSON.stringify({ ad: null }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: creatives } = await supabase
      .from("ad_creatives")
      .select("id, campaign_id, title, subtitle, cta_text, click_url, media_url, media_type, thumbnail_url, external_video_url, creative_type")
      .in("campaign_id", eligibleCampaigns.map((c) => c.id))
      .eq("is_active", true);

    if (!creatives?.length) {
      return new Response(
        JSON.stringify({ ad: null }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const candidates = creatives
      .filter((cr) => eligibleCampaigns.some((c) => c.id === cr.campaign_id))
      .map((cr) => {
        const camp = eligibleCampaigns.find((c) => c.id === cr.campaign_id)!;
        return {
          campaign_id: camp.id,
          creative_id: cr.id,
          campaign_name: camp.name,
          campaign_type: camp.campaign_type,
          creative_type: cr.creative_type,
          title: cr.title,
          subtitle: cr.subtitle,
          cta_text: cr.cta_text,
          click_url: cr.click_url,
          media_url: cr.media_url,
          media_type: cr.media_type,
          thumbnail_url: cr.thumbnail_url,
          external_video_url: cr.external_video_url,
          internal_type: camp.internal_type,
          internal_id: camp.internal_id,
        };
      });

    if (candidates.length === 1) {
      return new Response(
        JSON.stringify({ ad: candidates[0] }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let userContext = "Гость (без профиля)";
    if (user_id) {
      const { data: likedTracks } = await supabase
        .from("track_likes")
        .select("track_id")
        .eq("user_id", user_id)
        .limit(50);

      const trackIds = likedTracks?.map((l) => l.track_id) || [];
      const { data: myTracks } = await supabase
        .from("tracks")
        .select("genre_id")
        .eq("user_id", user_id)
        .limit(20);

      const genreIds = new Set<string>();
      myTracks?.forEach((t) => {
        if (t.genre_id) genreIds.add(t.genre_id);
      });

      if (trackIds.length > 0) {
        const { data: tracks } = await supabase
          .from("tracks")
          .select("genre_id")
          .in("id", trackIds);
        tracks?.forEach((t) => {
          if (t.genre_id) genreIds.add(t.genre_id);
        });
      }

      if (genreIds.size > 0) {
        const { data: genres } = await supabase
          .from("genres")
          .select("name_ru")
          .in("id", [...genreIds]);
        const names = genres?.map((g) => g.name_ru).filter(Boolean) || [];
        userContext = names.length > 0
          ? `Пользователь: интересы ${names.join(", ")}`
          : "Пользователь: интересы не определены";
      } else {
        userContext = "Пользователь: интересы не определены";
      }
    }

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN || candidates.length < 2) {
      const idx = Math.floor(Math.random() * candidates.length);
      return new Response(
        JSON.stringify({ ad: candidates[idx] }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const adsText = candidates
      .map((a, i) => `${i + 1}. ${a.campaign_name} (${a.campaign_type})${a.title ? ` — ${a.title}` : ""}`)
      .join("\n");

    const systemPrompt = `Ты подбираешь рекламу для пользователя музыкальной платформы.
Ответь СТРОГО одним числом — номер рекламы (1–${candidates.length}), наиболее подходящей пользователю.`;

    const userPrompt = `${userContext}\n\nРекламы:\n${adsText}\n\nНомер лучшей:`;

    const agentId = Deno.env.get("TIMEWEB_AGENT_ID") || "";
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${agentId}/v1/chat/completions`;
    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
      },
      body: JSON.stringify({
        model: "deepseek-v3",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: 0.2,
        max_tokens: 5,
      }),
    });

    let idx = 0;
    if (response.ok) {
      const data = await response.json();
      const text = data.choices?.[0]?.message?.content?.trim() || "";
      const num = parseInt(text.replace(/\D/g, ""), 10);
      if (num >= 1 && num <= candidates.length) {
        idx = num - 1;
      }
    }

    return new Response(
      JSON.stringify({ ad: candidates[idx] }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[ad-targeting] Error:", error);
    return new Response(
      JSON.stringify({ ad: null, fallback: true }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
