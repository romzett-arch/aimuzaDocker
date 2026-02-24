import type { AutomodResult } from "./types.ts";
import { callDeepSeek } from "./deepseek.ts";

export async function checkRateLimit(supabase: any, userId: string): Promise<AutomodResult | null> {
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

export function checkStopwords(
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
    try {
      const escaped = lowerWord.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const regex = new RegExp(`(?:^|[\\s.,!?;:()\\[\\]{}\"'\\-–—/])${escaped}(?:$|[\\s.,!?;:()\\[\\]{}\"'\\-–—/])`, "i");
      if (regex.test(` ${lowerText} `)) {
        matched.push(word);
      }
    } catch {
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

export function checkLinks(
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

export function checkRegex(
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

export async function checkNewbie(
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

export async function checkDuplicate(supabase: any, userId: string, text: string): Promise<AutomodResult | null> {
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

export async function checkAdPolicy(
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

  if (urls.length > 0 && userTrustLevel < minTrustLinks) {
    console.log(`[forum-automod] Ad policy: user trust_level=${userTrustLevel} < ${minTrustLinks}, links blocked`);
    return {
      allowed: false,
      reason: "ad_policy_trust",
      message: `Для размещения ссылок нужен уровень доверия ${minTrustLinks} (у вас: ${userTrustLevel}). Продолжайте активно общаться!`,
    };
  }

  if (urls.length > maxLinks) {
    console.log(`[forum-automod] Ad policy: too many links ${urls.length} > ${maxLinks}`);
    flags.push("ad_too_many_links");
    if (action === "auto_hide") setHidden(true);
    if (action === "block") {
      return { allowed: false, reason: "ad_too_many_links", message: `Максимум ${maxLinks} ссылок в одном сообщении.` };
    }
  }

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

export async function checkAIToxicity(
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
  }
}

export async function checkAISpam(
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

export async function checkAIQuality(
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
      }
    }
  } catch (error) {
    console.warn("[forum-automod] DeepSeek quality check error:", error);
  }
}
