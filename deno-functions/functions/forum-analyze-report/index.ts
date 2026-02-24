import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { AnalyzeRequest } from "./types.ts";
import { corsHeaders } from "./constants.ts";
import { jsonResponse, getCategoryLabel } from "./helpers.ts";
import { analyzeWithAI } from "./ai.ts";

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

    let contentText = "";
    let contentAuthorId: string | null = null;

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

    const snapshot = contentText.substring(0, 500);

    const { data: settings } = await supabase
      .from("forum_automod_settings")
      .select("key, value")
      .in("key", ["ai_moderation", "report_auto_action"]);

    const settingsMap: Record<string, unknown> = {};
    (settings || []).forEach((s: { key: string; value: unknown }) => {
      settingsMap[s.key] = s.value;
    });

    const reportConfig = (settingsMap["report_auto_action"] as Record<string, unknown>) || {};
    const autoActionThreshold = (reportConfig.confidence_threshold as number) || 0.8;
    const autoActionEnabled = reportConfig.enabled !== false;
    const autoWarnEnabled = reportConfig.auto_warn !== false;

    const aiResult = await analyzeWithAI(contentText, report.reason, report.details);

    console.log(
      `[analyze-report] AI verdict: ${aiResult.verdict}, confidence: ${aiResult.confidence}, category: ${aiResult.category}`
    );

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

    const shouldAutoAction =
      autoActionEnabled &&
      aiResult.verdict === "violation" &&
      (aiResult.confidence >= autoActionThreshold || reportCount >= 3);

    if (shouldAutoAction && contentAuthorId) {
      console.log(
        `[analyze-report] Auto-actioning: confidence=${aiResult.confidence}, reportCount=${reportCount}`
      );

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

      if (autoWarnEnabled) {
        const violationQuote = contentText.substring(0, 200);
        const warningReason = `Автоматическое предупреждение за нарушение правил форума.\n\nКатегория: ${getCategoryLabel(aiResult.category)}\nЦитата: «${violationQuote}»${violationQuote.length < contentText.length ? "..." : ""}`;

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
          },
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
