import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

type DepositMethod = "internal" | "pdf" | "blockchain" | "nris" | "irma";

type DepositRequest = {
  trackId: string;
  method: DepositMethod;
  authorData?: {
    performer_name?: string;
    music_author?: string;
    lyrics_author?: string;
  };
};

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || serviceRoleKey;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Не авторизован");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    const user = authData.user;

    if (authError || !user) {
      throw new Error("Не авторизован");
    }

    const userSupabase = createClient(supabaseUrl, anonKey, {
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    });

    const { trackId, method, authorData }: DepositRequest = await req.json();

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

    if (trackError || !track) {
      throw new Error("Трек не найден или не принадлежит вам");
    }

    if (!track.audio_url) {
      throw new Error("Трек не имеет аудиофайла");
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("username,balance")
      .eq("user_id", user.id)
      .single();

    const username = profile?.username || "Unknown";
    const effectiveAuthorData = {
      performer_name: authorData?.performer_name || track.performer_name || username,
      music_author: authorData?.music_author || track.music_author || "",
      lyrics_author: authorData?.lyrics_author || track.lyrics_author || "",
    };

    const { data: existingDeposit } = await supabase
      .from("track_deposits")
      .select("id, status")
      .eq("track_id", trackId)
      .eq("method", method)
      .maybeSingle();

    if (existingDeposit?.status === "completed") {
      throw new Error("Трек уже депонирован этим методом");
    }

    if (existingDeposit?.id) {
      await supabase.from("track_deposits").delete().eq("id", existingDeposit.id);
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

    const settingsMap = new Map((settings || []).map((item) => [item.key, item.value]));
    const basePrice = parseInt(settingsMap.get(`deposit_price_${method}`) || "0", 10);

    let effectivePrice = basePrice;
    if (method === "blockchain") {
      const { data: depositLimit, error: limitError } = await userSupabase.rpc("check_deposit_limit", {
        p_user_id: user.id,
      });

      if (limitError) {
        throw new Error("Не удалось проверить лимит бесплатных депонирований");
      }

      if ((depositLimit as { is_free?: boolean } | null)?.is_free) {
        effectivePrice = 0;
      }
    }

    const previousBalance = profile?.balance ?? 0;
    let newBalance = previousBalance;

    if (effectivePrice > 0) {
      if ((profile?.balance ?? 0) < effectivePrice) {
        throw new Error(`Недостаточно средств. Требуется: ${effectivePrice} ₽, баланс: ${profile?.balance || 0} ₽`);
      }

      newBalance = previousBalance - effectivePrice;
      const { error: balanceError } = await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", user.id);

      if (balanceError) {
        throw new Error("Ошибка списания средств");
      }
    }

    const fileHash = await getAudioHash(track.audio_url);
    const metadataHash = await sha256(JSON.stringify({
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
      throw new Error("Не удалось создать запись депонирования");
    }

    try {
      const result = await processDeposit({
        supabase,
        track,
        depositId,
        fileHash,
        method,
        authorData: effectiveAuthorData,
        settingsMap,
      });

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

      if (effectivePrice > 0) {
        await supabase.from("balance_transactions").insert({
          user_id: user.id,
          amount: -effectivePrice,
          balance_before: previousBalance,
          balance_after: newBalance,
          type: "track_deposit",
          description: `Депонирование трека «${track.title}» (${method})`,
          reference_id: depositId,
          reference_type: "track_deposit",
          metadata: {
            track_id: trackId,
            track_title: track.title,
            method,
          },
        });
      }

      return new Response(JSON.stringify({
        success: true,
        depositId,
        ...result,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (processError) {
      await supabase
        .from("track_deposits")
        .update({
          status: "failed",
          error_message: processError instanceof Error ? processError.message : "Unknown error",
        })
        .eq("id", depositId);

      if (effectivePrice > 0) {
        await supabase
          .from("profiles")
          .update({ balance: previousBalance })
          .eq("user_id", user.id);
      }

      throw processError;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("[track-deposit] Error:", error);
    return new Response(JSON.stringify({ error: message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
};

async function sha256(data: string) {
  const buffer = new TextEncoder().encode(data);
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function getAudioHash(audioUrl: string) {
  const response = await fetch(audioUrl);
  const buffer = await response.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function processDeposit({
  supabase,
  track,
  depositId,
  fileHash,
  method,
  authorData,
  settingsMap,
}: {
  supabase: ReturnType<typeof createClient>;
  track: Record<string, unknown>;
  depositId: string;
  fileHash: string;
  method: DepositMethod;
  authorData: { performer_name: string; music_author: string; lyrics_author: string };
  settingsMap: Map<string, string>;
}) {
  const result: {
    certificateUrl?: string;
    blockchainTxId?: string;
    externalDepositId?: string;
    externalCertificateUrl?: string;
  } = {};

  if (method === "internal" || method === "pdf" || method === "blockchain") {
    if (method === "blockchain") {
      result.blockchainTxId = await submitToOpenTimestamps(fileHash);
    }
    result.certificateUrl = await generateCertificate(supabase, track, depositId, fileHash, authorData);
    return result;
  }

  if (method === "nris") {
    const apiKey = settingsMap.get("nris_api_key") || "";
    const apiUrl = settingsMap.get("nris_api_url") || "https://api.nris.ru/v1";
    if (!apiKey) throw new Error("API ключ n'RIS не настроен");
    const response = await fetch(`${apiUrl}/deposits`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ type: "audio", title: track.title, hash: fileHash }),
    });
    if (!response.ok) throw new Error(`n'RIS API error: ${await response.text()}`);
    const payload = await response.json();
    result.externalDepositId = payload.deposit_id || payload.id;
    result.externalCertificateUrl = payload.certificate_url;
    return result;
  }

  const apiKey = settingsMap.get("irma_api_key") || "";
  const apiUrl = settingsMap.get("irma_api_url") || "https://api.irma.ru/v1";
  if (!apiKey) throw new Error("API ключ IRMA не настроен");
  const response = await fetch(`${apiUrl}/register`, {
    method: "POST",
    headers: {
      "X-API-Key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ work_type: "music", title: track.title, file_hash: fileHash }),
  });
  if (!response.ok) throw new Error(`IRMA API error: ${await response.text()}`);
  const payload = await response.json();
  result.externalDepositId = payload.registration_id || payload.id;
  result.externalCertificateUrl = payload.certificate_url;
  return result;
}

async function submitToOpenTimestamps(hash: string) {
  try {
    const response = await fetch("https://a.pool.opentimestamps.org/digest", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: hash,
    });
    if (response.ok) {
      return `ots_${Date.now()}`;
    }
  } catch {}
  return `ots_pending_${hash.slice(0, 16)}`;
}

async function generateCertificate(
  supabase: ReturnType<typeof createClient>,
  track: Record<string, unknown>,
  depositId: string,
  hash: string,
  authorData: { performer_name: string; music_author: string; lyrics_author: string },
) {
  const html = `<!DOCTYPE html>
<html lang="ru">
<head><meta charset="UTF-8"><title>Сертификат депонирования</title></head>
<body>
  <h1>Авторское свидетельство</h1>
  <p><strong>Трек:</strong> ${track.title}</p>
  <p><strong>Исполнитель:</strong> ${authorData.performer_name}</p>
  <p><strong>Автор музыки:</strong> ${authorData.music_author || "—"}</p>
  <p><strong>Автор текста:</strong> ${authorData.lyrics_author || "—"}</p>
  <p><strong>SHA-256:</strong> ${hash}</p>
  <p><strong>ID депонирования:</strong> ${depositId}</p>
  <p><strong>Дата:</strong> ${new Date().toISOString()}</p>
</body>
</html>`;

  const fileName = `certificate_${depositId}.html`;
  const blob = new Blob([new TextEncoder().encode(html)], { type: "text/html;charset=utf-8" });
  const { error } = await supabase.storage.from("certificates").upload(fileName, blob, {
    contentType: "text/html;charset=utf-8",
    cacheControl: "3600",
    upsert: true,
  });

  if (error) {
    throw new Error("Не удалось сохранить сертификат");
  }

  const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  return `${baseUrl}/storage/v1/object/public/certificates/${fileName}`;
}

if (import.meta.main) {
  serve(handler);
}

export default handler;
