import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { DepositRequest } from "./types.ts";
import { canonicalizeLyrics, generateEvidenceSignature, generateHash } from "./utils.ts";
import { upgradeOpenTimestamps } from "./services.ts";
import { confirmLyricsCertificate } from "./certificate.ts";
import { prepareLyricsArtifacts, recoverLyricsArtifacts } from "./artifacts.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

type ServiceClient = ReturnType<typeof createClient<any>>;
interface PendingLyricsDeposit {
  id: string;
  lyrics_id: string;
  user_id: string;
  content_hash: string;
  external_proof: string;
  certificate_url: string | null;
}

async function finalizeConfirmedDeposit(
  supabase: ServiceClient,
  currentDeposit: PendingLyricsDeposit,
  upgradedProof: string,
  confirmedAt: string,
): Promise<boolean> {
  const { data: updatedDeposit, error: updateError } = await supabase
    .from("lyrics_deposits")
    .update({
      status: "completed",
      proof_status: "external_confirmed",
      external_proof: upgradedProof,
      updated_at: confirmedAt,
    })
    .eq("id", currentDeposit.id)
    .neq("status", "completed")
    .select("id")
    .maybeSingle();
  if (updateError) throw updateError;
  if (!updatedDeposit) return false;

  await confirmLyricsCertificate(supabase, currentDeposit.certificate_url, confirmedAt);
  await supabase.from("notifications").insert({
    user_id: currentDeposit.user_id,
    type: "lyrics_deposited",
    title: "Цифровая защита готова",
    message: "Независимая проверка времени завершена. Доказательство и сертификат обновлены.",
    target_type: "lyrics",
    target_id: currentDeposit.lyrics_id,
  });
  return true;
}

const workerStateKey = "__AIMUZA_LYRICS_DEPOSIT_STATUS_WORKER__";
const workerGlobal = globalThis as Record<string, unknown>;

async function refreshPendingLyricsDeposits(): Promise<void> {
  const state = workerGlobal[workerStateKey] as { running: boolean };
  if (state.running) return;
  state.running = true;

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseServiceKey) return;

    const supabase = createClient<any>(supabaseUrl, supabaseServiceKey);
    await recoverLyricsArtifacts(supabase);
    const { data: pendingDeposits, error } = await supabase
      .from("lyrics_deposits")
      .select("*")
      .eq("method", "blockchain")
      .in("status", ["pending", "processing"])
      .not("external_proof", "is", null)
      .order("created_at", { ascending: true })
      .limit(50);
    if (error) throw error;

    for (const deposit of pendingDeposits || []) {
      try {
        const upgraded = await upgradeOpenTimestamps(deposit.content_hash, deposit.external_proof);
        if (upgraded.confirmed) {
          await finalizeConfirmedDeposit(supabase, deposit, upgraded.proofBase64, new Date().toISOString());
        }
      } catch (error) {
        console.warn(`[lyrics-deposit] status check failed for ${deposit.id}:`, error);
      }
    }
  } catch (error) {
    console.warn("[lyrics-deposit] recovery failed", error);
  } finally {
    state.running = false;
  }
}

if (!workerGlobal[workerStateKey]) {
  workerGlobal[workerStateKey] = { running: false };
  setTimeout(() => void refreshPendingLyricsDeposits(), 15_000);
  setInterval(() => void refreshPendingLyricsDeposits(), 60_000);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient<any>(supabaseUrl, supabaseServiceKey);

    const authHeader = req.headers.get("authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Требуется авторизация" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Неверный токен авторизации" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const payload = await req.json() as DepositRequest & { action?: string; deposit_id?: string; use_promo?: boolean };

    if (payload.action === "check_status") {
      if (!payload.deposit_id) {
        return new Response(JSON.stringify({ error: "Не указана запись депонирования" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: currentDeposit, error: currentError } = await supabase
        .from("lyrics_deposits")
        .select("*")
        .eq("id", payload.deposit_id)
        .eq("user_id", user.id)
        .single();

      if (currentError || !currentDeposit) {
        return new Response(JSON.stringify({ error: "Запись депонирования не найдена" }), {
          status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (currentDeposit.status === "completed" && currentDeposit.proof_status === "external_confirmed") {
        return new Response(JSON.stringify({
          success: true,
          confirmed: true,
          status: "completed",
          message: "Цифровая защита подтверждена",
        }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      if (currentDeposit.artifacts_pending) {
        return Response.json({
          success: true, confirmed: false, status: "pending",
          message: "Цифровая метка сохранена. Доказательство ещё готовится", nextCheckSeconds: 60,
        }, { headers: corsHeaders });
      }

      if (!currentDeposit.content_hash || !currentDeposit.external_proof) {
        return new Response(JSON.stringify({ error: "Файл цифрового доказательства отсутствует" }), {
          status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const upgraded = await upgradeOpenTimestamps(
        currentDeposit.content_hash,
        currentDeposit.external_proof,
      );

      if (!upgraded.confirmed) {
        return new Response(JSON.stringify({
          success: true,
          confirmed: false,
          status: "pending",
          message: "Цифровая метка создана. Независимое подтверждение ещё готовится",
          nextCheckSeconds: 60,
        }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      const confirmedAt = new Date().toISOString();
      await finalizeConfirmedDeposit(
        supabase,
        currentDeposit,
        upgraded.proofBase64,
        confirmedAt,
      );

      return new Response(JSON.stringify({
        success: true,
        confirmed: true,
        status: "completed",
        message: "Цифровая защита подтверждена",
      }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { lyrics_id, method, author_name } = payload;

    const { data: lyrics, error: lyricsError } = await supabase
      .from("lyrics_items")
      .select("*")
      .eq("id", lyrics_id)
      .eq("user_id", user.id)
      .single();

    if (lyricsError || !lyrics) {
      return new Response(
        JSON.stringify({ error: "Текст не найден или нет доступа" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: existingDeposit } = await supabase
      .from("lyrics_deposits")
      .select("id, status")
      .eq("lyrics_id", lyrics_id)
      .eq("method", "blockchain")
      .in("status", ["pending", "processing", "completed"])
      .maybeSingle();

    if (existingDeposit) {
      return new Response(
        JSON.stringify({ error: "Текст уже депонирован" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (method !== "blockchain") {
      return new Response(JSON.stringify({ error: "Для текстов доступна единая цифровая защита AIMUZA" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const contentHash = await generateHash(canonicalizeLyrics(lyrics.title, lyrics.content));
    const depositedAt = new Date().toISOString();
    const depositId = `LYR-${crypto.randomUUID().replaceAll("-", "").slice(0, 20).toUpperCase()}`;
    const recordId = crypto.randomUUID();
    const signingSecret = Deno.env.get("DEPOSIT_SIGNING_SECRET") || supabaseServiceKey;
    const timestampHash = await generateEvidenceSignature(
      `${depositId}|${contentHash}|${depositedAt}|${user.id}`,
      signingSecret,
    );

    const { data: deposit, error: depositError } = await supabase.rpc("begin_lyrics_deposit_artifacts", {
      p_record_id: recordId,
      p_lyrics_id: lyrics_id,
      p_user_id: user.id,
      p_content_hash: contentHash,
      p_timestamp_signature: timestampHash,
      p_external_id: depositId,
      p_author_name: author_name || null,
      p_deposited_at: depositedAt,
      p_work_title: lyrics.title,
      p_use_promo: payload.use_promo === true,
    });
    if (depositError?.message === "promo_unavailable") {
      return Response.json({ error: "Бонус на депонирование закончился. Обновите остаток и подтвердите новую цену." }, { status: 409, headers: corsHeaders });
    }
    if (depositError?.message?.startsWith("Недостаточно средств")) {
      return Response.json({ error: depositError.message }, { status: 402, headers: corsHeaders });
    }
    if (depositError) throw new Error(depositError.message || "Ошибка записи депонирования");

    const certificateUrl = await prepareLyricsArtifacts(supabase, recordId, user.id).catch((error) => {
      console.warn(`[lyrics-deposit] artifacts queued for ${recordId}`, error);
      return null;
    });

    return new Response(
      JSON.stringify({
        success: true,
        deposit,
        certificateUrl,
        artifactsPending: certificateUrl === null,
        tariffFreeDeposit: Boolean((deposit as { tariff_free_deposit?: boolean } | null)?.tariff_free_deposit),
        freeRemaining: Number((deposit as { free_remaining?: number } | null)?.free_remaining || 0),
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Ошибка при депонировании";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
