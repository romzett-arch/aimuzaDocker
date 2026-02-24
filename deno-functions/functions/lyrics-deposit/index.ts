import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { DepositRequest } from "./types.ts";
import { generateHash } from "./utils.ts";
import { submitToOpenTimestamps, submitToNris, submitToIrma } from "./services.ts";
import { generateLyricsCertificate } from "./certificate.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

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

    const { lyricsId, method, authorName } = await req.json() as DepositRequest;
    console.log(`Processing lyrics deposit: ${lyricsId}, method: ${method}`);

    const { data: lyrics, error: lyricsError } = await supabase
      .from("lyrics_items")
      .select("*")
      .eq("id", lyricsId)
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
      .eq("lyrics_id", lyricsId)
      .eq("status", "completed")
      .single();

    if (existingDeposit) {
      return new Response(
        JSON.stringify({ error: "Текст уже депонирован" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: priceSetting } = await supabase
      .from("app_settings")
      .select("value")
      .eq("key", "lyrics_deposit_price")
      .single();

    const depositPrice = parseInt(priceSetting?.value || "50", 10);

    const { data: profile } = await supabase
      .from("profiles")
      .select("balance")
      .eq("user_id", user.id)
      .single();

    if (!profile || (profile.balance || 0) < depositPrice) {
      return new Response(
        JSON.stringify({ error: `Недостаточно средств. Требуется: ${depositPrice} ₽` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const contentHash = await generateHash(lyrics.content + lyrics.title + new Date().toISOString());
    const timestampHash = await generateHash(contentHash + Date.now().toString());

    let externalId: string | null = null;
    let certificateUrl: string | null = null;

    if (method === "blockchain") {
      externalId = await submitToOpenTimestamps(contentHash);
    } else if (method === "nris") {
      const nrisApiKey = Deno.env.get("NRIS_API_KEY");
      const nrisApiUrl = Deno.env.get("NRIS_API_URL") || "https://api.nris.ru";

      if (!nrisApiKey) {
        return new Response(
          JSON.stringify({ error: "Сервис n'RIS временно недоступен" }),
          { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const result = await submitToNris(
        { ...lyrics, author_name: authorName },
        contentHash,
        nrisApiKey,
        nrisApiUrl
      );
      externalId = result.depositId;
      certificateUrl = result.certificateUrl || null;
    } else if (method === "irma") {
      const irmaApiKey = Deno.env.get("IRMA_API_KEY");
      const irmaApiUrl = Deno.env.get("IRMA_API_URL") || "https://api.irma.ru";

      if (!irmaApiKey) {
        return new Response(
          JSON.stringify({ error: "Сервис IRMA временно недоступен" }),
          { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const result = await submitToIrma(
        { ...lyrics, author_name: authorName },
        contentHash,
        irmaApiKey,
        irmaApiUrl
      );
      externalId = result.depositId;
      certificateUrl = result.certificateUrl || null;
    }

    const depositId = `LYR-${Date.now()}-${Math.random().toString(36).substr(2, 9).toUpperCase()}`;

    if (method === "internal" || !certificateUrl) {
      certificateUrl = await generateLyricsCertificate(
        supabase,
        lyrics,
        contentHash,
        depositId,
        authorName || ""
      );
    }

    await supabase
      .from("profiles")
      .update({ balance: (profile.balance || 0) - depositPrice })
      .eq("user_id", user.id);

    const { data: deposit, error: depositError } = await supabase
      .from("lyrics_deposits")
      .insert({
        lyrics_id: lyricsId,
        user_id: user.id,
        method,
        status: "completed",
        content_hash: contentHash,
        timestamp_hash: timestampHash,
        external_id: externalId || depositId,
        certificate_url: certificateUrl,
        author_name: authorName,
        price_rub: depositPrice,
        deposited_at: new Date().toISOString(),
      })
      .select()
      .single();

    if (depositError) {
      console.error("Error creating deposit:", depositError);
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user.id);
      throw depositError;
    }

    await supabase.from("notifications").insert({
      user_id: user.id,
      type: "lyrics_deposited",
      title: "Текст депонирован",
      message: `Ваш текст "${lyrics.title}" успешно депонирован`,
      target_type: "lyrics",
      target_id: lyricsId,
    });

    console.log(`Lyrics deposit completed: ${deposit.id}`);

    return new Response(
      JSON.stringify({
        success: true,
        deposit,
        certificateUrl
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: unknown) {
    console.error("Lyrics deposit error:", error);
    const message = error instanceof Error ? error.message : "Ошибка при депонировании";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
