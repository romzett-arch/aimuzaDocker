import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./types.ts";
import { generateHash, getAudioHash } from "./utils.ts";
import { beginTrackDeposit, failTrackDepositAndRefund } from "./billing.ts";
import { getEffectiveAuthorData, validateTrack } from "./validation.ts";
import { processDeposit } from "./deposit-processor.ts";
import type { DepositRequest, DepositError } from "./types.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Не авторизован");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      throw new Error("Не авторизован");
    }

    const { trackId, method, authorData }: DepositRequest = await req.json();
    if (method !== "blockchain") {
      throw new Error("Доступна только цифровая защита AIMUZA");
    }
    console.log(`Deposit request: track=${trackId}, method=${method}, user=${user.id}`);

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select(`
        id, title, audio_url, duration, created_at,
        performer_name, music_author, lyrics_author, user_id,
        genre:genres(name_ru)
      `)
      .eq("id", trackId)
      .eq("user_id", user.id)
      .single();

    const { data: profile } = await supabase
      .from("profiles")
      .select("username")
      .eq("user_id", user.id)
      .single();

    if (trackError || !track) {
      throw new Error("Трек не найден или не принадлежит вам");
    }
    validateTrack(track, trackId);
    const username = profile?.username || "Unknown";
    const effectiveAuthorData = getEffectiveAuthorData(authorData, track, username);

    console.log("Generating audio hash...");
    const fileHash = await getAudioHash(track.audio_url);

    const metadataHash = await generateHash(JSON.stringify({
      title: track.title,
      performer: effectiveAuthorData.performer_name,
      musicAuthor: effectiveAuthorData.music_author,
      lyricsAuthor: effectiveAuthorData.lyrics_author,
      duration: track.duration,
      fileHash,
      timestamp: new Date().toISOString(),
    }));

    const depositId = crypto.randomUUID();
    const billing = await beginTrackDeposit(supabase, {
      depositId,
      trackId,
      userId: user.id,
      method,
      fileHash,
      metadataHash,
      performerName: effectiveAuthorData.performer_name,
      lyricsAuthor: effectiveAuthorData.lyrics_author,
    });
    if (billing.price <= 0) {
      console.log(`Deposit is free for method ${method}`);
    }

    let externalServiceCompleted = false;
    try {
      const result = await processDeposit(
        supabase,
        track,
        fileHash,
        depositId,
        effectiveAuthorData,
      );
      externalServiceCompleted = true;

      const { error: completionError } = await supabase
        .from("track_deposits")
        .update({
          status: "completed",
          completed_at: new Date().toISOString(),
          certificate_url: result.certificateUrl,
          pdf_url: result.pdfUrl,
          registry_url: result.registryUrl,
          certificate_html_hash: result.certificateHtmlHash,
          certificate_pdf_hash: result.certificatePdfHash,
          certificate_generated_at: result.certificateGeneratedAt,
          blockchain_tx_id: result.blockchainTxId,
          blockchain_proof_path: result.blockchainProofPath,
          blockchain_proof_url: result.blockchainProofUrl,
          blockchain_proof_status: result.blockchainProofStatus,
          blockchain_submitted_at: result.blockchainSubmittedAt,
          external_deposit_id: result.externalDepositId,
          external_certificate_url: result.externalCertificateUrl,
        })
        .eq("id", depositId);
      if (completionError) {
        console.error("Deposit completion update error:", completionError);
        throw new Error("Услуга выполнена, но статус не удалось сохранить. Обратитесь в поддержку.");
      }

      const { error: notificationError } = await supabase.from("notifications").insert({
        user_id: user.id,
        type: "system",
        title: "Депонирование завершено",
        message: `Трек "${track.title}" успешно депонирован`,
        target_type: "track",
        target_id: trackId,
      });
      if (notificationError) console.error("Deposit notification error:", notificationError);

      console.log(`Deposit completed: ${depositId}`);

      return new Response(
        JSON.stringify({
          success: true,
          depositId,
          ...result,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );

    } catch (processError: unknown) {
      const error = processError as DepositError;
      console.error("Process error:", error);

      if (!externalServiceCompleted) {
        await failTrackDepositAndRefund(supabase, depositId, error.message || "Unknown error");
      } else {
        console.error(`CRITICAL: deposit ${depositId} completed externally but local completion failed; no refund issued`);
      }
      throw error;
    }

  } catch (error: unknown) {
    const err = error as Error;
    console.error("Deposit error:", err);
    return new Response(
      JSON.stringify({ error: err.message }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
