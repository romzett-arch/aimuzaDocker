import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface AutomodRequest {
  content: string;
  title?: string;
  type: "post" | "topic";
}

interface AutomodResult {
  allowed: boolean;
  reason?: string;
  message?: string;
  flags?: string[];
  human_flags?: string[];
  auto_hidden?: boolean;
  hidden_reason?: string;
}

/** Map technical flag names to human-readable descriptions */
function humanizeFlag(flag: string): string {
  const map: Record<string, string> = {
    stopwords: "Обнаружена ненормативная лексика",
    too_many_links: "Слишком много ссылок",
    blacklisted_link: "Запрещённая ссылка",
    regex_match: "Обнаружено запрещённое выражение",
    newbie_premod: "Премодерация нового пользователя",
    ad_too_many_links: "Подозрение на рекламу: много ссылок",
    ad_external_links: "Подозрение на рекламу: внешние ссылки",
    ai_toxic: "Обнаружен токсичный контент",
    ai_insult: "Обнаружены оскорбления",
    ai_hate: "Обнаружен язык ненависти",
    ai_threat: "Обнаружены угрозы",
    ai_spam: "Обнаружен спам",
    ai_low_quality: "Низкое качество контента",
  };
  // Handle dynamic flags like "ad_ai_promo"
  if (flag.startsWith("ad_ai_")) return "Обнаружена реклама";
  if (flag.startsWith("ai_")) return map[flag] || "Нарушение правил (AI-проверка)";
  return map[flag] || "Нарушение правил форума";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ allowed: false, reason: "unauthorized", message: "Необходимо войти в систему" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      console.error("Auth error:", authError);
      return new Response(
        JSON.stringify({ allowed: false, reason: "unauthorized", message: "Не авторизован" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body: AutomodRequest = await req.json();
    const { content, title, type } = body;
    const textToCheck = title ? `${title} ${content}` : content;
    const flags: string[] = [];
    let autoHidden = false;

    console.log(`[forum-automod] Checking ${type} from user ${user.id}, length: ${textToCheck.length}`);

    // Fetch all settings at once
    const { data: settings } = await supabase
      .from("forum_automod_settings")
      .select("key, value");

    const settingsMap: Record<string, any> = {};
    (settings || []).forEach((s: any) => { settingsMap[s.key] = s.value; });

    // ── 0. Get user trust level ───────────────────────────────
    const { data: userStats } = await supabase
      .from("forum_user_stats")
      .select("trust_level")
      .eq("user_id", user.id)
      .maybeSingle();
    const userTrustLevel = userStats?.trust_level ?? 0;

    // ── 1. Rate Limit Check ────────────────────────────────────
    const result1 = await checkRateLimit(supabase, user.id);
    if (result1) return jsonResponse(result1);

    // ── 2. Stopwords Check ─────────────────────────────────────
    checkStopwords(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });

    // ── 3. Link Filter ─────────────────────────────────────────
    checkLinks(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });

    // ── 4. Regex Filters ───────────────────────────────────────
    checkRegex(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });

    // ── 5. Newbie Premoderation ─────────────────────────────────
    await checkNewbie(supabase, settingsMap, user.id, userTrustLevel, flags, (v: boolean) => { autoHidden = autoHidden || v; });

    // ── 6. Duplicate Content Check ─────────────────────────────
    const dupResult = await checkDuplicate(supabase, user.id, textToCheck);
    if (dupResult) return jsonResponse(dupResult);

    // ── 6.5. Advertising / Promo Policy ─────────────────────────
    const adResult = await checkAdPolicy(supabase, settingsMap, user.id, userTrustLevel, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    if (adResult) return jsonResponse(adResult);

    // ── 7–9. AI Checks (skip for trusted users: trust_level ≥ 2) ──
    const aiTrustThreshold = settingsMap["ai_moderation"]?.skip_trust_level ?? 2;
    if (userTrustLevel < aiTrustThreshold) {
      console.log(`[forum-automod] Running AI checks for user trust_level=${userTrustLevel} (threshold=${aiTrustThreshold})`);
      await checkAIToxicity(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
      await checkAISpam(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
      await checkAIQuality(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    } else {
      console.log(`[forum-automod] Skipping AI checks for trusted user trust_level=${userTrustLevel}`);
    }

    // ── Result ──────────────────────────────────────────────────
    const humanFlags = flags.map(f => humanizeFlag(f));
    const result: AutomodResult = {
      allowed: true,
      flags: flags.length > 0 ? flags : undefined,
      human_flags: humanFlags.length > 0 ? humanFlags : undefined,
      auto_hidden: autoHidden || undefined,
    };

    if (autoHidden) {
      result.message = "Контент будет проверен модератором";
      result.hidden_reason = humanFlags.length > 0
        ? `Сообщение скрыто: ${humanFlags.join(", ").toLowerCase()}`
        : "Сообщение скрыто автоматической модерацией";
      console.log(`[forum-automod] Content flagged for auto-hide: ${flags.join(", ")}`);
    }

    console.log(`[forum-automod] Result: allowed=${result.allowed}, flags=${flags.join(",")}, auto_hidden=${autoHidden}`);
    return jsonResponse(result);

  } catch (error) {
    console.error("[forum-automod] Error:", error);
    return jsonResponse({ allowed: true, error: "Automod check failed, allowing by default" });
  }
});

// ── Helper: JSON Response ──────────────────────────────────
function jsonResponse(data: any, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ── Check: Rate Limit ──────────────────────────────────────
async function checkRateLimit(supabase: any, userId: string): Promise<AutomodResult | null> {
  const { data: rateLimitResult } = await supabase.rpc("forum_check_rate_limit", {
    p_user_id: userId,
  });

  if (rateLimitResult && !rateLimitResult.allowed) {
    console.log(`[forum-automod] Rate limit hit: ${rateLimitResult.message}`);
    return {
      allowed: false,
      reason: rateLimitResult.reason,
      message: rateLimitResult.message,
    };
  }
  return null;
}

// ── Check: Stopwords (with word-boundary regex) ───────────
function checkStopwords(
  settingsMap: Record<string, any>,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const config = settingsMap["stopwords"];
  if (!config?.enabled || !config?.words?.length) return;

  const lowerText = text.toLowerCase();
  const matched: string[] = [];

  for (const word of config.words) {
    const lowerWord = word.toLowerCase();
    // Use word-boundary regex for accurate matching
    // \b doesn't work well with Cyrillic, so use lookaround for non-word chars or string edges
    try {
      const escaped = lowerWord.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const regex = new RegExp(`(?:^|[\\s.,!?;:()\\[\\]{}\"'\\-–—/])${escaped}(?:$|[\\s.,!?;:()\\[\\]{}\"'\\-–—/])`, "i");
      if (regex.test(` ${lowerText} `)) {
        matched.push(word);
      }
    } catch {
      // Fallback to includes for invalid patterns
      if (lowerText.includes(lowerWord)) {
        matched.push(word);
      }
    }
  }

  if (matched.length > 0) {
    console.log(`[forum-automod] Stopwords matched: ${matched.join(", ")}`);
    flags.push("stopwords");
    setHidden(true);
  }
}

// ── Check: Links ───────────────────────────────────────────
function checkLinks(
  settingsMap: Record<string, any>,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const config = settingsMap["link_filter"];
  if (!config?.enabled) return;

  const urlRegex = /https?:\/\/[^\s<>"']+/gi;
  const urls = text.match(urlRegex) || [];
  const maxLinks = config.max_links || 5;

  if (urls.length > maxLinks) {
    console.log(`[forum-automod] Too many links: ${urls.length} > ${maxLinks}`);
    flags.push("too_many_links");
    setHidden(true);
  }

  const blacklist: string[] = config.blacklist_domains || [];
  if (blacklist.length > 0) {
    for (const url of urls) {
      try {
        const domain = new URL(url).hostname.toLowerCase();
        if (blacklist.some((bl: string) => domain.includes(bl.toLowerCase()))) {
          console.log(`[forum-automod] Blacklisted domain: ${domain}`);
          flags.push("blacklisted_link");
          setHidden(true);
          break;
        }
      } catch { /* Invalid URL */ }
    }
  }
}

// ── Check: Regex Filters ───────────────────────────────────
function checkRegex(
  settingsMap: Record<string, any>,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const config = settingsMap["regex_filters"];
  if (!config?.enabled || !config?.patterns?.length) return;

  for (const pattern of config.patterns) {
    try {
      const regex = new RegExp(pattern, "gi");
      if (regex.test(text)) {
        console.log(`[forum-automod] Regex matched: ${pattern}`);
        flags.push("regex_match");
        setHidden(true);
        break;
      }
    } catch {
      console.warn(`[forum-automod] Invalid regex pattern: ${pattern}`);
    }
  }
}

// ── Check: Newbie Premod ───────────────────────────────────
async function checkNewbie(
  supabase: any,
  settingsMap: Record<string, any>,
  userId: string,
  userTrustLevel: number,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const config = settingsMap["newbie_premod"];
  if (!config?.enabled) return;

  const maxTrustLevel = config.max_trust_level ?? 0;
  if (userTrustLevel <= maxTrustLevel) {
    console.log(`[forum-automod] Newbie premod: trust_level=${userTrustLevel}`);
    flags.push("newbie_premod");
    setHidden(true);
  }
}

// ── Check: Duplicate Content ───────────────────────────────
async function checkDuplicate(supabase: any, userId: string, text: string): Promise<AutomodResult | null> {
  const contentHash = text.substring(0, 200).trim().toLowerCase();
  if (contentHash.length <= 20) return null;

  const { data: recentPosts } = await supabase
    .from("forum_posts")
    .select("id, content")
    .eq("user_id", userId)
    .gte("created_at", new Date(Date.now() - 60 * 60 * 1000).toISOString())
    .limit(10);

  const isDuplicate = (recentPosts || []).some((p: any) =>
    p.content.substring(0, 200).trim().toLowerCase() === contentHash
  );

  if (isDuplicate) {
    console.log(`[forum-automod] Duplicate content detected`);
    return {
      allowed: false,
      reason: "duplicate",
      message: "Такое сообщение уже было отправлено. Пожалуйста, не дублируйте контент.",
    };
  }
  return null;
}

// ── Check: Advertising / Promo Policy ──────────────────────
async function checkAdPolicy(
  supabase: any,
  settingsMap: Record<string, any>,
  userId: string,
  userTrustLevel: number,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
): Promise<AutomodResult | null> {
  const policy = settingsMap["ad_policy"];
  if (!policy?.enabled) return null;

  const urlRegex = /https?:\/\/[^\s<>"']+/gi;
  const urls = text.match(urlRegex) || [];
  const whitelist: string[] = policy.whitelist_domains || [];
  const blacklist: string[] = policy.blacklist_domains || [];
  const maxLinks = policy.max_links_per_post || 5;
  const minTrustLinks = policy.min_trust_level_links ?? 1;
  const minTrustPromo = policy.min_trust_level_promo ?? 2;
  const action = policy.action || "auto_hide";

  // ── 1. Check trust level for links ──
  if (urls.length > 0 && userTrustLevel < minTrustLinks) {
    console.log(`[forum-automod] Ad policy: user trust_level=${userTrustLevel} < ${minTrustLinks}, links blocked`);
    return {
      allowed: false,
      reason: "ad_policy_trust",
      message: `Для размещения ссылок нужен уровень доверия ${minTrustLinks} (у вас: ${userTrustLevel}). Продолжайте активно общаться!`,
    };
  }

  // ── 2. Check max links ──
  if (urls.length > maxLinks) {
    console.log(`[forum-automod] Ad policy: too many links ${urls.length} > ${maxLinks}`);
    flags.push("ad_too_many_links");
    if (action === "auto_hide") setHidden(true);
    if (action === "block") {
      return { allowed: false, reason: "ad_too_many_links", message: `Максимум ${maxLinks} ссылок в одном сообщении.` };
    }
  }

  // ── 3. Check blacklisted domains ──
  for (const url of urls) {
    try {
      const domain = new URL(url).hostname.toLowerCase();
      if (blacklist.some((bl: string) => domain.includes(bl.toLowerCase()))) {
        console.log(`[forum-automod] Ad policy: blacklisted domain ${domain}`);
        return {
          allowed: false,
          reason: "ad_blacklisted_domain",
          message: "Ссылки на этот ресурс запрещены на форуме.",
        };
      }
    } catch { /* Invalid URL */ }
  }

  // ── 4. Check non-whitelisted external links (promo detection) ──
  const externalUrls = urls.filter((url) => {
    try {
      const domain = new URL(url).hostname.toLowerCase();
      return !whitelist.some((wl: string) => domain.includes(wl.toLowerCase()));
    } catch { return false; }
  });

  if (externalUrls.length > 0 && userTrustLevel < minTrustPromo) {
    console.log(`[forum-automod] Ad policy: external links from low-trust user, trust=${userTrustLevel}`);
    flags.push("ad_external_links");
    if (action === "auto_hide") setHidden(true);
    if (action === "block") {
      return { allowed: false, reason: "ad_external_links", message: `Размещение внешних ссылок доступно с уровня доверия ${minTrustPromo}.` };
    }
  }

  // ── 5. Daily promo limit ──
  if (externalUrls.length > 0) {
    const maxPromo = policy.max_promo_per_day || 3;
    const { data: todayPosts } = await supabase
      .from("forum_posts")
      .select("id, content")
      .eq("user_id", userId)
      .gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
      .limit(50);

    const promoCount = (todayPosts || []).filter((p: any) => {
      const postUrls = p.content.match(urlRegex) || [];
      return postUrls.some((u: string) => {
        try {
          const d = new URL(u).hostname.toLowerCase();
          return !whitelist.some((wl: string) => d.includes(wl.toLowerCase()));
        } catch { return false; }
      });
    }).length;

    if (promoCount >= maxPromo) {
      console.log(`[forum-automod] Ad policy: daily promo limit reached ${promoCount} >= ${maxPromo}`);
      return {
        allowed: false,
        reason: "ad_daily_limit",
        message: `Лимит промо-постов в сутки: ${maxPromo}. Попробуйте завтра.`,
      };
    }
  }

  // ── 6. AI hidden ad detection ──
  if (policy.ai_ad_detection && text.length >= 50) {
    try {
      const systemPrompt = `Ты — AI-модератор музыкального форума. Определи, содержит ли текст СКРЫТУЮ рекламу.
Скрытая реклама = завуалированные промо-посты, нативная реклама, "случайные" рекомендации коммерческих сервисов, партнёрские ссылки, рекрутинг.
НЕ реклама = обсуждение музыки, рекомендации бесплатных инструментов, обмен опытом, помощь другим, шеринг своих треков.
Отвечай ТОЛЬКО JSON: {"is_ad": true/false, "confidence": 0.0-1.0, "ad_type": "none|native_ad|affiliate|recruitment|promo|spam", "reason": "краткое пояснение"}`;

      const result = await callDeepSeek(systemPrompt, text.substring(0, 1000));
      if (result) {
        const jsonMatch = result.match(/\{[^}]*\}/s);
        if (jsonMatch) {
          const parsed = JSON.parse(jsonMatch[0]);
          if (parsed.is_ad === true && (parsed.confidence || 0) >= 0.75) {
            console.log(`[forum-automod] Ad policy AI: type=${parsed.ad_type}, confidence=${parsed.confidence}, reason=${parsed.reason}`);
            flags.push(`ad_ai_${parsed.ad_type || "detected"}`);
            if (action === "auto_hide") setHidden(true);
            if (action === "block") {
              return { allowed: false, reason: "ad_detected", message: "Контент распознан как реклама и заблокирован." };
            }
          }
        }
      }
    } catch (error) {
      console.warn("[forum-automod] Ad policy AI check error:", error);
    }
  }

  return null;
}

// ── DeepSeek AI via Timeweb Agent API ──────────────────────
const TIMEWEB_AGENT_ACCESS_ID = 'e046a9e4-43f6-47bc-a39f-8a9de8778d02';

async function callDeepSeek(systemPrompt: string, userMessage: string): Promise<string | null> {
  const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
  if (!TIMEWEB_TOKEN) {
    console.warn("[forum-automod] TIMEWEB_AGENT_TOKEN not configured");
    return null;
  }

  const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;

  const response = await fetch(apiUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${TIMEWEB_TOKEN}`,
    },
    body: JSON.stringify({
      model: "deepseek-v3.2",
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userMessage },
      ],
      temperature: 0.1,
      max_tokens: 500,
    }),
  });

  if (!response.ok) {
    console.warn(`[forum-automod] DeepSeek API error: ${response.status}`);
    return null;
  }

  const data = await response.json();
  return data.choices?.[0]?.message?.content || null;
}

// ── Check: AI Toxicity (via DeepSeek / Timeweb) ────────────
async function checkAIToxicity(
  settingsMap: Record<string, any>,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const aiConfig = settingsMap["ai_moderation"];
  if (!aiConfig?.enabled) return;

  const minLength = aiConfig.min_text_length || 20;
  if (text.length < minLength) return;

  try {
    const systemPrompt = `Ты — AI-модератор музыкального форума. Анализируй текст на:
1. Токсичность, оскорбления, hate speech
2. Спам, рекламу, фишинг
3. Угрозы, буллинг, домогательства
4. Откровенный NSFW-контент
5. Мошенничество, фейки

НЕ считай нарушением: критику музыки, дискуссии, сленг, мнения, юмор.

Отвечай ТОЛЬКО JSON: {"toxic": true/false, "confidence": 0.0-1.0, "category": "none|toxicity|spam|threats|nsfw|fraud", "reason": "краткое пояснение на русском"}`;

    const result = await callDeepSeek(systemPrompt, text.substring(0, 1000));
    if (!result) return;

    const jsonMatch = result.match(/\{[^}]*\}/s);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      const threshold = aiConfig.confidence_threshold || 0.7;
      if (parsed.toxic === true && (parsed.confidence || 0) >= threshold) {
        console.log(`[forum-automod] DeepSeek toxicity: category=${parsed.category}, confidence=${parsed.confidence}, reason=${parsed.reason}`);
        flags.push(`ai_${parsed.category || "toxic"}`);
        setHidden(true);
      }
    }
  } catch (error) {
    console.warn("[forum-automod] DeepSeek toxicity check error:", error);
    // Fail open — don't block on AI errors
  }
}

// ── AI: Spam detection (ads, scam links, crypto spam) ──────
async function checkAISpam(
  settingsMap: Record<string, any>,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const aiConfig = settingsMap["ai_moderation"];
  if (!aiConfig?.enabled || !aiConfig?.spam_detection) return;
  if (text.length < 30) return;

  try {
    const systemPrompt = `Определи, является ли текст спамом на музыкальном форуме.
Спам = реклама, крипто-схемы, казино, сомнительные ссылки, бессмысленный набор символов, SEO-спам.
НЕ спам = обсуждение музыки, просьбы о фидбеке, шеринг своих треков, вопросы.

Отвечай ТОЛЬКО JSON: {"spam": true/false, "confidence": 0.0-1.0, "reason": "краткое пояснение"}`;

    const result = await callDeepSeek(systemPrompt, text.substring(0, 800));
    if (!result) return;

    const jsonMatch = result.match(/\{[^}]*\}/s);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      if (parsed.spam === true && (parsed.confidence || 0) >= 0.75) {
        console.log(`[forum-automod] DeepSeek spam detected: ${parsed.reason}`);
        flags.push("ai_spam");
        setHidden(true);
      }
    }
  } catch (error) {
    console.warn("[forum-automod] DeepSeek spam check error:", error);
  }
}

// ── AI: Language quality check (gibberish, all-caps flood) ──
async function checkAIQuality(
  settingsMap: Record<string, any>,
  text: string,
  flags: string[],
  setHidden: (v: boolean) => void
) {
  const aiConfig = settingsMap["ai_moderation"];
  if (!aiConfig?.enabled || !aiConfig?.quality_check) return;
  if (text.length < 10) return;

  try {
    const systemPrompt = `Оцени качество текста для музыкального форума.
Низкое качество = полная бессмыслица, случайные символы, весь текст КАПСОМ (>80%), бот-генерация.
Допустимо = разговорный стиль, сленг, короткие ответы, эмодзи, музыкальные термины.

Отвечай ТОЛЬКО JSON: {"low_quality": true/false, "reason": "краткое пояснение"}`;

    const result = await callDeepSeek(systemPrompt, text.substring(0, 500));
    if (!result) return;

    const jsonMatch = result.match(/\{[^}]*\}/s);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      if (parsed.low_quality === true) {
        console.log(`[forum-automod] DeepSeek low quality: ${parsed.reason}`);
        flags.push("ai_low_quality");
        // Don't auto-hide, just flag for review
      }
    }
  } catch (error) {
    console.warn("[forum-automod] DeepSeek quality check error:", error);
  }
}
