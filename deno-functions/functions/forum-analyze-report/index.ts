/**
 * forum-analyze-report
 * AI-powered report analysis: when a user reports content,
 * this function analyzes it with DeepSeek and auto-actions if confident.
 *
 * Flow:
 * 1. Fetch reported content (post or topic)
 * 2. Run AI analysis (is it a real violation?)
 * 3. Update report with AI verdict
 * 4. If high confidence: auto-hide content + auto-warn author
 * 5. If multiple reports on same target: escalate priority
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const TIMEWEB_AGENT_ACCESS_ID = "e046a9e4-43f6-47bc-a39f-8a9de8778d02";

interface AnalyzeRequest {
  reportId: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { reportId }: AnalyzeRequest = await req.json();
    if (!reportId) {
      return jsonResponse({ error: "reportId required" }, 400);
    }

    console.log(`[analyze-report] Processing report ${reportId}`);

    // ── 1. Fetch the report ──
    const { data: report, error: reportError } = await supabase
      .from("forum_reports")
      .select("*")
      .eq("id", reportId)
      .maybeSingle();

    if (reportError || !report) {
      console.error("[analyze-report] Report not found:", reportError);
      return jsonResponse({ error: "Report not found" }, 404);
    }

    if (report.status !== "pending") {
      console.log("[analyze-report] Report already processed, skipping");
      return jsonResponse({ status: "skipped", reason: "already_processed" });
    }

    // ── 2. Fetch the reported content ──
    let contentText = "";
    let contentAuthorId: string | null = null;
    let contentTitle: string | null = null;

    if (report.post_id) {
      const { data: post } = await supabase
        .from("forum_posts")
        .select("content, user_id")
        .eq("id", report.post_id)
        .maybeSingle();

      if (post) {
        contentText = post.content;
        contentAuthorId = post.user_id;
      }
    } else if (report.topic_id) {
      const { data: topic } = await supabase
        .from("forum_topics")
        .select("title, content, user_id")
        .eq("id", report.topic_id)
        .maybeSingle();

      if (topic) {
        contentText = `${topic.title}\n\n${topic.content}`;
        contentTitle = topic.title;
        contentAuthorId = topic.user_id;
      }
    }

    if (!contentText) {
      console.warn("[analyze-report] No content found for report");
      await supabase
        .from("forum_reports")
        .update({
          ai_verdict: "error",
          ai_reason: "Контент не найден",
          target_user_id: contentAuthorId,
        })
        .eq("id", reportId);
      return jsonResponse({ status: "error", reason: "content_not_found" });
    }

    // Save content snapshot for admin reference
    const snapshot = contentText.substring(0, 500);

    // ── 3. Fetch settings ──
    const { data: settings } = await supabase
      .from("forum_automod_settings")
      .select("key, value")
      .in("key", ["ai_moderation", "report_auto_action"]);

    const settingsMap: Record<string, any> = {};
    (settings || []).forEach((s: any) => {
      settingsMap[s.key] = s.value;
    });

    const aiConfig = settingsMap["ai_moderation"] || {};
    const reportConfig = settingsMap["report_auto_action"] || {};
    const autoActionThreshold = reportConfig.confidence_threshold || 0.8;
    const autoActionEnabled = reportConfig.enabled !== false; // default true
    const autoWarnEnabled = reportConfig.auto_warn !== false; // default true

    // ── 4. Run AI analysis ──
    const aiResult = await analyzeWithAI(contentText, report.reason, report.details);

    console.log(
      `[analyze-report] AI verdict: ${aiResult.verdict}, confidence: ${aiResult.confidence}, category: ${aiResult.category}`
    );

    // ── 5. Update report with AI result ──
    await supabase
      .from("forum_reports")
      .update({
        ai_verdict: aiResult.verdict,
        ai_confidence: aiResult.confidence,
        ai_category: aiResult.category,
        ai_reason: aiResult.reason,
        content_snapshot: snapshot,
        target_user_id: contentAuthorId,
      })
      .eq("id", reportId);

    // ── 6. Check report count for this target ──
    let reportCount = 1;
    if (report.post_id) {
      const { count } = await supabase
        .from("forum_reports")
        .select("*", { count: "exact", head: true })
        .eq("post_id", report.post_id)
        .eq("status", "pending");
      reportCount = count || 1;
    } else if (report.topic_id) {
      const { count } = await supabase
        .from("forum_reports")
        .select("*", { count: "exact", head: true })
        .eq("topic_id", report.topic_id)
        .is("post_id", null)
        .eq("status", "pending");
      reportCount = count || 1;
    }

    // ── 7. Auto-action if confident enough OR multiple reports ──
    const shouldAutoAction =
      autoActionEnabled &&
      aiResult.verdict === "violation" &&
      (aiResult.confidence >= autoActionThreshold || reportCount >= 3);

    if (shouldAutoAction && contentAuthorId) {
      console.log(
        `[analyze-report] Auto-actioning: confidence=${aiResult.confidence}, reportCount=${reportCount}`
      );

      // Hide content
      const table = report.post_id ? "forum_posts" : "forum_topics";
      const targetId = report.post_id || report.topic_id;

      await supabase
        .from(table)
        .update({
          is_hidden: true,
          hidden_by: "00000000-0000-0000-0000-000000000000",
          hidden_at: new Date().toISOString(),
          hidden_reason: `AI-модерация: ${aiResult.reason}`,
        })
        .eq("id", targetId);

      // Auto-resolve the report
      await supabase
        .from("forum_reports")
        .update({
          status: "resolved",
          resolution_note: `AI авто-модерация: ${aiResult.category} (${Math.round(aiResult.confidence * 100)}%)`,
          resolved_by: "00000000-0000-0000-0000-000000000000",
          resolved_at: new Date().toISOString(),
          auto_actioned: true,
        })
        .eq("id", reportId);

      // Auto-warn the author (with quote of violation)
      if (autoWarnEnabled) {
        const violationQuote = contentText.substring(0, 200);
        const warningReason = `Автоматическое предупреждение за нарушение правил форума.\n\nКатегория: ${getCategoryLabel(aiResult.category)}\nЦитата: «${violationQuote}»${violationQuote.length < contentText.length ? "..." : ""}`;

        // Fetch default warning expiry
        const { data: expirySetting } = await supabase
          .from("forum_automod_settings")
          .select("value")
          .eq("key", "warn_expiry_days")
          .maybeSingle();
        const expiryDays = expirySetting ? Number(expirySetting.value) : 90;
        const expiresAt = new Date(Date.now() + expiryDays * 86400000).toISOString();

        await supabase.from("forum_warnings").insert({
          user_id: contentAuthorId,
          issued_by: "00000000-0000-0000-0000-000000000000",
          reason: warningReason,
          severity: aiResult.confidence >= 0.9 ? "warning" : "notice",
          expires_at: expiresAt,
          post_id: report.post_id || null,
          topic_id: report.topic_id || null,
        });

        // Update warning count in user stats
        const { count: warnCount } = await supabase
          .from("forum_warnings")
          .select("*", { count: "exact", head: true })
          .eq("user_id", contentAuthorId)
          .eq("is_active", true);

        await supabase
          .from("forum_user_stats")
          .update({
            warnings_count: warnCount || 0,
            updated_at: new Date().toISOString(),
          })
          .eq("user_id", contentAuthorId);
      }

      // Log mod action
      await supabase.from("forum_mod_logs").insert([
        {
          moderator_id: "00000000-0000-0000-0000-000000000000",
          action: "ai_auto_moderate",
          target_type: report.post_id ? "post" : "topic",
          target_id: report.post_id || report.topic_id,
          details: {
            report_id: reportId,
            ai_verdict: aiResult.verdict,
            ai_confidence: aiResult.confidence,
            ai_category: aiResult.category,
            report_count: reportCount,
            auto_warned: autoWarnEnabled,
            author_id: contentAuthorId,
          } as any,
        },
      ]);

      return jsonResponse({
        status: "auto_actioned",
        verdict: aiResult.verdict,
        confidence: aiResult.confidence,
        category: aiResult.category,
        hidden: true,
        warned: autoWarnEnabled,
      });
    }

    return jsonResponse({
      status: "analyzed",
      verdict: aiResult.verdict,
      confidence: aiResult.confidence,
      category: aiResult.category,
      auto_actioned: false,
    });
  } catch (error) {
    console.error("[analyze-report] Error:", error);
    return jsonResponse(
      { error: error instanceof Error ? error.message : "Unknown error" },
      500
    );
  }
});

// ── Helpers ──

function jsonResponse(data: any, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getCategoryLabel(category: string): string {
  const labels: Record<string, string> = {
    toxicity: "Токсичность / Оскорбления",
    spam: "Спам / Реклама",
    threats: "Угрозы / Буллинг",
    nsfw: "NSFW-контент",
    fraud: "Мошенничество",
    offtopic: "Оффтопик",
    copyright: "Нарушение авторских прав",
    none: "Нарушение не обнаружено",
  };
  return labels[category] || category;
}

interface AIAnalysisResult {
  verdict: "violation" | "clean" | "uncertain";
  confidence: number;
  category: string;
  reason: string;
}

async function analyzeWithAI(
  content: string,
  reportReason: string,
  reportDetails: string | null
): Promise<AIAnalysisResult> {
  const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
  if (!TIMEWEB_TOKEN) {
    console.warn("[analyze-report] TIMEWEB_AGENT_TOKEN not configured, using heuristic");
    return heuristicAnalysis(content);
  }

  const systemPrompt = `Ты — AI-модератор музыкального форума. На этот пост/тему поступила жалоба.

Причина жалобы: "${reportReason}"
${reportDetails ? `Детали: "${reportDetails}"` : ""}

Проанализируй контент и определи:
1. Является ли контент РЕАЛЬНЫМ нарушением правил?
2. Категория нарушения (если есть)

Категории нарушений:
- toxicity: прямые оскорбления, мат, hate speech, унижение
- spam: реклама, промо, бессмысленный флуд
- threats: угрозы, буллинг, запугивание
- nsfw: откровенный контент
- fraud: мошенничество, фейки
- offtopic: полностью не по теме
- copyright: нарушение авторских прав

ВАЖНО:
- НЕ считай нарушением: критику музыки, сарказм, мнения, дискуссии, профессиональные споры
- Учитывай КОНТЕКСТ музыкального форума
- Будь строг к реальным оскорблениям, но лоялен к креативным дискуссиям

Отвечай СТРОГО JSON: {"verdict": "violation"|"clean"|"uncertain", "confidence": 0.0-1.0, "category": "...", "reason": "краткое пояснение на русском до 100 символов"}`;

  try {
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
      },
      body: JSON.stringify({
        model: "deepseek-v3.2",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: content.substring(0, 1500) },
        ],
        temperature: 0.1,
        max_tokens: 300,
      }),
    });

    if (!response.ok) {
      console.warn(`[analyze-report] DeepSeek API error: ${response.status}`);
      return heuristicAnalysis(content);
    }

    const data = await response.json();
    const resultText = data.choices?.[0]?.message?.content;
    if (!resultText) return heuristicAnalysis(content);

    const jsonMatch = resultText.match(/\{[^}]*\}/s);
    if (!jsonMatch) return heuristicAnalysis(content);

    const parsed = JSON.parse(jsonMatch[0]);
    return {
      verdict: parsed.verdict || "uncertain",
      confidence: Math.min(1, Math.max(0, parsed.confidence || 0)),
      category: parsed.category || "none",
      reason: (parsed.reason || "Анализ завершён").substring(0, 200),
    };
  } catch (error) {
    console.warn("[analyze-report] AI analysis failed:", error);
    return heuristicAnalysis(content);
  }
}

/**
 * Fallback heuristic when AI is unavailable
 */
function heuristicAnalysis(content: string): AIAnalysisResult {
  const lowerContent = content.toLowerCase();

  // Basic profanity check (same words as stopwords list)
  const profanityPatterns = [
    /\bбля[дть]?\b/i,
    /\bхуй/i,
    /\bпизд/i,
    /\bебл[аоя]/i,
    /\bсука?\b/i,
    /\bмуда[кч]/i,
    /\bгандон/i,
    /\bдолбо[её]б/i,
    /\bдебил/i,
    /\bидиот/i,
    /\bтупой/i,
    /\bурод/i,
  ];

  const matched = profanityPatterns.filter((p) => p.test(lowerContent));

  if (matched.length >= 2) {
    return {
      verdict: "violation",
      confidence: 0.85,
      category: "toxicity",
      reason: "Обнаружена нецензурная лексика (эвристика)",
    };
  }

  if (matched.length === 1) {
    return {
      verdict: "uncertain",
      confidence: 0.6,
      category: "toxicity",
      reason: "Возможная нецензурная лексика (требует ручной проверки)",
    };
  }

  return {
    verdict: "uncertain",
    confidence: 0.3,
    category: "none",
    reason: "Автоматический анализ не обнаружил явных нарушений",
  };
}
