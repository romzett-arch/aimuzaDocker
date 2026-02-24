import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./types.ts";
import { generateHash, getAudioHash } from "./utils.ts";
import { checkAndDeductBalance, refundBalance } from "./billing.ts";
import { getEffectiveAuthorData, validateTrack } from "./validation.ts";
import { processDepositByMethod } from "./deposit-processor.ts";
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

    const username = profile?.username || "Unknown";
    const effectiveAuthorData = getEffectiveAuthorData(authorData, track, username);

    if (trackError || !track) {
      throw new Error("Трек не найден или не принадлежит вам");
    }
    validateTrack(track, trackId);

    const { data: existingDeposit } = await supabase
      .from("track_deposits")
      .select("id, status")
      .eq("track_id", trackId)
      .eq("method", method)
      .single();

    if (existingDeposit) {
      if (existingDeposit.status === "completed") {
        throw new Error("Трек уже депонирован этим методом");
      }
      await supabase
        .from("track_deposits")
        .delete()
        .eq("id", existingDeposit.id);
    }

    const { data: settings } = await supabase
      .from("settings")
      .select("key, value")
      .in("key", [
        `deposit_price_${method}`,
        "nris_api_key",
        "nris_api_url",
        "irma_api_key",
        "irma_api_url",
      ]);

    const settingsMap = new Map(settings?.map(s => [s.key, s.value]) || []);
    const priceKey = `deposit_price_${method}`;
    const priceValue = settingsMap.get(priceKey);
    const price = parseInt(priceValue || "0", 10);

    console.log(`Deposit pricing: key=${priceKey}, rawValue=${priceValue}, parsedPrice=${price}`);

    await checkAndDeductBalance(supabase, user.id, price);
    if (price <= 0) {
      console.log(`Deposit is free for method ${method}`);
    }

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
    const { error: insertError } = await supabase
      .from("track_deposits")
      .upsert({
        id: depositId,
        track_id: trackId,
        user_id: user.id,
        method,
        status: "processing",
        file_hash: fileHash,
        metadata_hash: metadataHash,
        performer_name: effectiveAuthorData.performer_name,
        lyrics_author: effectiveAuthorData.lyrics_author,
      });

    if (insertError) {
      console.error("Insert error:", insertError);
      throw new Error("Не удалось создать запись депонирования");
    }

    try {
      const result = await processDepositByMethod(
        method,
        supabase,
        track,
        fileHash,
        depositId,
        effectiveAuthorData,
        settingsMap
      );

      await supabase
        .from("track_deposits")
        .update({
          status: "completed",
          completed_at: new Date().toISOString(),
          certificate_url: result.certificateUrl,
          blockchain_tx_id: result.blockchainTxId,
          external_deposit_id: result.externalDepositId,
          external_certificate_url: result.externalCertificateUrl,
        })
        .eq("id", depositId);

      await supabase.from("notifications").insert({
        user_id: user.id,
        type: "system",
        title: "Депонирование завершено",
        message: `Трек "${track.title}" успешно депонирован`,
        target_type: "track",
        target_id: trackId,
      });

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

      await supabase
        .from("track_deposits")
        .update({
          status: "failed",
          error_message: error.message || "Unknown error",
        })
        .eq("id", depositId);

      await refundBalance(supabase, user.id, price);
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
