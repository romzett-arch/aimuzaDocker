import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { normalizeSunoRecords, refundPendingGenerationLogs, SUNO_API_BASE, SUNO_TERMINAL_FAILURES } from "../../shared/suno.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await supabaseClient.auth.getClaims(token);
    if (claimsError || !claimsData?.claims?.sub) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const adminUserId = claimsData.claims.sub;
    const { data: roles } = await supabaseAdmin
      .from("user_roles")
      .select("role")
      .eq("user_id", adminUserId);

    const isAdmin = roles?.some((role) => role.role === "admin" || role.role === "super_admin");
    if (!isAdmin) {
      return new Response(
        JSON.stringify({ error: "Forbidden: admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { trackId } = await req.json();
    if (!trackId) {
      return new Response(
        JSON.stringify({ error: "Missing trackId" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: track, error: trackError } = await supabaseAdmin
      .from("tracks")
      .select("*")
      .eq("id", trackId)
      .single();

    if (trackError || !track) {
      return new Response(
        JSON.stringify({ error: "Track not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const taskIdMatch = track.description?.match(/\[task_id:\s*([^\]]+)\]/);
    const taskId = taskIdMatch?.[1]?.trim();

    if (!taskId) {
      if (track.audio_url) {
        return new Response(
          JSON.stringify({
            success: true,
            status: "completed",
            message: "Трек уже содержит аудио. task_id не найден, но восстановление не требуется.",
            audio_url: track.audio_url,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      return new Response(
        JSON.stringify({ success: false, message: "Трек не содержит task_id для проверки" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (!SUNO_API_KEY) {
      return new Response(
        JSON.stringify({ success: false, message: "На сервере не настроен SUNO_API_KEY" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const statusResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/record-info?taskId=${encodeURIComponent(taskId)}`, {
      method: "GET",
      headers: { "Authorization": `Bearer ${SUNO_API_KEY}` },
    });

    const statusData = await statusResponse.json();
    if (statusData.code === 200 && statusData.data) {
      const taskStatus = statusData.data.status;
      const records = normalizeSunoRecords(
        (statusData.data.response?.sunoData || statusData.data.data || []) as Array<Record<string, unknown>>,
      );

      if (SUNO_TERMINAL_FAILURES.has(taskStatus)) {
        const errorMessage =
          statusData.data.fail_reason || statusData.data.error_message || "Генерация отклонена сервисом";

        await supabaseAdmin
          .from("tracks")
          .update({ status: "failed", error_message: errorMessage })
          .eq("id", trackId);

        const refundResult = await refundPendingGenerationLogs(supabaseAdmin, {
          userId: track.user_id,
          trackIds: [trackId],
          reason: `Возврат за ошибку генерации: ${errorMessage}`,
          fullMessage: errorMessage,
        });

        return new Response(
          JSON.stringify({
            success: false,
            status: "failed",
            message: errorMessage,
            refunded: refundResult.refundedAmount > 0,
            refundAmount: refundResult.refundedAmount,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const targetRecord = /\(v2\)\s*$/.test(track.title || "") ? records[1] : records[0];
      if (targetRecord?.audioUrl) {
        await supabaseAdmin
          .from("tracks")
          .update({
            audio_url: targetRecord.audioUrl,
            cover_url: targetRecord.imageUrl,
            duration: targetRecord.duration ? Math.round(Number(targetRecord.duration)) : track.duration,
            status: "completed",
            error_message: null,
            suno_audio_id: targetRecord.id,
          })
          .eq("id", trackId);

        await supabaseAdmin
          .from("generation_logs")
          .update({ status: "completed" })
          .eq("track_id", trackId)
          .in("status", ["pending", "failed"]);

        return new Response(
          JSON.stringify({
            success: true,
            status: "completed",
            message: "Трек восстановлен из Suno record-info",
            audio_url: targetRecord.audioUrl,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      return new Response(
        JSON.stringify({
          success: false,
          status: taskStatus || "processing",
          message: `Статус: ${taskStatus}. Трек ещё генерируется.`,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (statusData.status === 404 || statusData.error === "Not Found") {
      if (track.audio_url) {
        await supabaseAdmin
          .from("tracks")
          .update({ status: "completed", error_message: null })
          .eq("id", trackId);

        return new Response(
          JSON.stringify({
            success: true,
            status: "completed",
            message: "Задача уже исчезла из Suno, но аудио у нас сохранено.",
            audio_url: track.audio_url,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const refundResult = await refundPendingGenerationLogs(supabaseAdmin, {
        userId: track.user_id,
        trackIds: [trackId],
        reason: "Возврат за недоступный результат генерации",
        fullMessage: "Задача удалена с сервера Suno и аудио недоступно. Средства возвращены.",
      });

      await supabaseAdmin
        .from("tracks")
        .update({
          status: "failed",
          error_message: "Задача удалена с сервера Suno и аудио недоступно.",
        })
        .eq("id", trackId);

      return new Response(
        JSON.stringify({
          success: false,
          status: "expired",
          message: "Задача удалена с сервера Suno и аудио недоступно.",
          refunded: refundResult.refundedAmount > 0,
          refundAmount: refundResult.refundedAmount,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    return new Response(
      JSON.stringify({
        success: false,
        status: "unknown",
        message: `Suno API ответил: ${statusData.msg || statusData.error || "Unknown error"}`,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("[Admin Recheck] Error:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
