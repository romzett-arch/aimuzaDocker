import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface AuthorData {
  performer_name: string;
  music_author: string;
  lyrics_author: string;
}

interface DepositRequest {
  trackId: string;
  method: "internal" | "pdf" | "blockchain" | "nris" | "irma";
  authorData?: AuthorData;
}

interface DepositError extends Error {
  message: string;
}

// Генерация SHA-256 хеша
async function generateHash(data: string): Promise<string> {
  const encoder = new TextEncoder();
  const dataBuffer = encoder.encode(data);
  const hashBuffer = await crypto.subtle.digest("SHA-256", dataBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

// Переписываем старые Supabase URL на текущий API (после миграции storage на aimuza.ru)
function resolveAudioUrl(url: string): string {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "https://aimuza.ru";
  const oldSupabase = /https:\/\/[a-z]+\.supabase\.co/;
  if (oldSupabase.test(url)) {
    const path = new URL(url).pathname;
    return `${supabaseUrl}${path}`;
  }
  return url;
}

// Получаем хеш аудиофайла
async function getAudioHash(audioUrl: string): Promise<string> {
  const resolvedUrl = resolveAudioUrl(audioUrl);
  try {
    const response = await fetch(resolvedUrl);
    const buffer = await response.arrayBuffer();
    const hashBuffer = await crypto.subtle.digest("SHA-256", buffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
  } catch (error) {
    console.error("Error fetching audio for hash:", error);
    throw new Error("Не удалось получить аудиофайл для хеширования");
  }
}

// OpenTimestamps — API ожидает 32 байта (binary), не hex-строку
async function submitToOpenTimestamps(hashHex: string): Promise<string> {
  const hashBytes = new Uint8Array(
    hashHex.match(/.{2}/g)!.map((b) => parseInt(b, 16))
  );
  const calendars = [
    "https://a.pool.opentimestamps.org/digest",
    "https://b.pool.opentimestamps.org/digest",
    "https://finney.calendar.eternitywall.com/digest",
  ];
  for (const calendar of calendars) {
    try {
      const resp = await fetch(calendar, {
        method: "POST",
        headers: {
          "Content-Type": "application/octet-stream",
          Accept: "application/vnd.opentimestamps.v1",
        },
        body: hashBytes,
      });
      if (resp.ok) {
        return `ots_${Date.now()}`;
      }
    } catch (e) {
      console.log(`[OTS] ${calendar} failed:`, e);
    }
  }
  return `ots_pending_${hashHex.substring(0, 16)}`;
}

// n'RIS API интеграция
async function submitToNris(
  track: any,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ n'RIS не настроен");
  }

  try {
    const response = await fetch(`${apiUrl}/deposits`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        type: "audio",
        title: track.title,
        author: track.performer_name || track.profiles?.username,
        hash: hash,
        metadata: {
          duration: track.duration,
          genre: track.genre?.name_ru,
          created_at: track.created_at,
          lyrics_author: track.lyrics_author,
          music_author: track.music_author,
        },
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`n'RIS API error: ${error}`);
    }

    const result = await response.json();
    return {
      depositId: result.deposit_id || result.id,
      certificateUrl: result.certificate_url,
    };
  } catch (error) {
    console.error("n'RIS error:", error);
    throw error;
  }
}

// IRMA API интеграция
async function submitToIrma(
  track: any,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ IRMA не настроен");
  }

  try {
    const response = await fetch(`${apiUrl}/register`, {
      method: "POST",
      headers: {
        "X-API-Key": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        work_type: "music",
        title: track.title,
        creators: [
          {
            role: "author",
            name: track.performer_name || track.profiles?.username,
          },
          ...(track.music_author ? [{ role: "composer", name: track.music_author }] : []),
          ...(track.lyrics_author ? [{ role: "lyricist", name: track.lyrics_author }] : []),
        ],
        file_hash: hash,
        additional_info: {
          duration_seconds: track.duration,
          genre: track.genre?.name_ru,
        },
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`IRMA API error: ${error}`);
    }

    const result = await response.json();
    return {
      depositId: result.registration_id || result.id,
      certificateUrl: result.certificate_url,
    };
  } catch (error) {
    console.error("IRMA error:", error);
    throw error;
  }
}

// Генерация PDF сертификата
async function generatePdfCertificate(
  supabase: any,
  track: any,
  hash: string,
  depositId: string,
  authorData: { performer_name: string; music_author: string; lyrics_author: string }
): Promise<string> {
  const publicBase = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  const verifyUrl = `${publicBase}/verify?hash=${encodeURIComponent(hash)}`;
  const qrCodeUrl = `https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=${encodeURIComponent(verifyUrl)}`;

  const certificateData = {
    title: "Авторское свидетельство",
    trackTitle: track.title || "Без названия",
    performer: authorData.performer_name || "Не указан",
    musicAuthor: authorData.music_author || "",
    lyricsAuthor: authorData.lyrics_author || "",
    fileHash: hash,
    depositId: depositId,
    depositDate: new Date().toISOString(),
    platform: "aimuza.ru",
    label: "Лейбл НОТА - ФЕЯ",
    labelFull: 'ООО "Музыкальный лейбл НОТА-ФЕЯ"',
    verifyUrl,
    qrCodeUrl,
  };

  const formattedDate = new Date(certificateData.depositDate).toLocaleString('ru-RU', {
    day: '2-digit',
    month: '2-digit', 
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  });

  // HTML сертификат с QR-кодом и стилями для печати
  const htmlContent = `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Сертификат депонирования - ${certificateData.trackTitle}</title>
  <style>
    @media print {
      body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      .no-print { display: none !important; }
      @page { size: A4; margin: 15mm; }
    }
    
    * { box-sizing: border-box; margin: 0; padding: 0; }
    
    body { 
      font-family: 'Times New Roman', 'Georgia', serif; 
      padding: 40px; 
      max-width: 800px; 
      margin: 0 auto; 
      background: #fff;
      color: #1a1a1a;
      line-height: 1.5;
    }
    
    .certificate {
      border: 3px double #2c3e50;
      padding: 40px;
      background: linear-gradient(135deg, #fefefe 0%, #f8f9fa 100%);
      position: relative;
    }
    
    .certificate::before {
      content: '';
      position: absolute;
      top: 10px;
      left: 10px;
      right: 10px;
      bottom: 10px;
      border: 1px solid #bdc3c7;
      pointer-events: none;
    }
    
    .header { 
      text-align: center; 
      border-bottom: 2px solid #2c3e50; 
      padding-bottom: 25px; 
      margin-bottom: 30px; 
    }
    
    .logo-section {
      margin-bottom: 15px;
    }
    
    .label-name {
      font-size: 14px;
      color: #555;
      font-weight: 500;
      letter-spacing: 1px;
      margin-bottom: 5px;
    }
    
    .website {
      font-size: 18px;
      color: #2c3e50;
      font-weight: bold;
      letter-spacing: 2px;
    }
    
    .title { 
      font-size: 32px; 
      font-weight: bold; 
      color: #1a1a1a; 
      text-transform: uppercase;
      letter-spacing: 3px;
      margin-top: 20px;
    }
    
    .subtitle { 
      font-size: 16px; 
      color: #666; 
      margin-top: 10px;
      font-style: italic;
    }
    
    .content {
      display: grid;
      gap: 18px;
    }
    
    .section { 
      display: grid;
      grid-template-columns: 180px 1fr;
      align-items: start;
      gap: 15px;
    }
    
    .label { 
      font-weight: bold; 
      color: #2c3e50;
      font-size: 14px;
      padding-top: 10px;
    }
    
    .value { 
      padding: 12px 15px; 
      background: #fff; 
      border: 1px solid #ddd;
      border-radius: 4px;
      font-size: 15px;
      box-shadow: inset 0 1px 3px rgba(0,0,0,0.05);
    }
    
    .hash { 
      font-family: 'Courier New', monospace; 
      font-size: 11px; 
      word-break: break-all;
      color: #555;
      letter-spacing: 0.5px;
    }
    
    .seal { 
      text-align: center; 
      margin: 35px 0 25px; 
    }
    
    .seal-container {
      display: inline-block;
      position: relative;
    }
    
    .seal-text { 
      display: inline-block; 
      padding: 20px 35px; 
      border: 4px double #2c3e50; 
      border-radius: 50%;
      font-size: 14px;
      font-weight: bold;
      color: #2c3e50;
      text-align: center;
      line-height: 1.4;
      background: linear-gradient(135deg, #fff 0%, #f0f0f0 100%);
    }
    
    .qr-section {
      text-align: center;
      margin: 25px 0 20px;
      padding: 15px;
      border: 1px dashed #bdc3c7;
      border-radius: 8px;
      background: #fafafa;
    }
    .qr-caption {
      font-size: 11px;
      color: #666;
      margin-bottom: 10px;
    }
    .qr-link { display: inline-block; }
    .qr-image { display: block; width: 120px; height: 120px; margin: 0 auto; }
    
    .footer { 
      margin-top: 30px; 
      padding-top: 20px; 
      border-top: 2px solid #2c3e50; 
      font-size: 12px; 
      color: #666; 
      text-align: center;
      line-height: 1.8;
    }
    
    .footer p {
      margin: 5px 0;
    }
    
    .footer .platform {
      font-weight: bold;
      color: #2c3e50;
      font-size: 14px;
      margin-top: 15px;
    }
    
    .print-btn {
      display: block;
      margin: 20px auto;
      padding: 12px 30px;
      background: #2c3e50;
      color: #fff;
      border: none;
      border-radius: 5px;
      font-size: 16px;
      cursor: pointer;
      font-family: inherit;
    }
    
    .print-btn:hover {
      background: #1a252f;
    }
  </style>
</head>
<body>
  <button class="print-btn no-print" onclick="window.print()">📄 Сохранить как PDF / Распечатать</button>
  
    <div class="certificate">
    <div class="header">
      <div class="logo-section">
        <div class="label-name">${certificateData.label}</div>
        <div class="website">сайт ${certificateData.platform}</div>
      </div>
      <div class="title">АВТОРСКОЕ СВИДЕТЕЛЬСТВО</div>
      <div class="subtitle">Музыкальное произведение</div>
    </div>
    
    <div class="content">
      <div class="section">
        <div class="label">Название произведения:</div>
        <div class="value">${certificateData.trackTitle}</div>
      </div>
      
      <div class="section">
        <div class="label">Исполнитель:</div>
        <div class="value">${certificateData.performer}</div>
      </div>
      
      ${certificateData.musicAuthor ? `<div class="section">
        <div class="label">Автор музыки:</div>
        <div class="value">${certificateData.musicAuthor}</div>
      </div>` : ''}
      
      ${certificateData.lyricsAuthor ? `<div class="section">
        <div class="label">Автор текста:</div>
        <div class="value">${certificateData.lyricsAuthor}</div>
      </div>` : ''}
      
      <div class="section">
        <div class="label">Цифровой отпечаток (SHA-256):</div>
        <div class="value hash">${certificateData.fileHash}</div>
      </div>
      
      <div class="section">
        <div class="label">Идентификатор:</div>
        <div class="value">${certificateData.depositId}</div>
      </div>
      
      <div class="section">
        <div class="label">Дата регистрации:</div>
        <div class="value">${formattedDate}</div>
      </div>
    </div>
    
    <div class="seal">
      <div class="seal-container">
        <div class="seal-text">НОТА-ФЕЯ<br/>✓ Verified</div>
      </div>
    </div>
    
    <div class="qr-section">
      <p class="qr-caption">Проверка подлинности — отсканируйте QR-код</p>
      <a href="${certificateData.verifyUrl}" target="_blank" rel="noopener" class="qr-link">
        <img src="${certificateData.qrCodeUrl}" alt="QR-код для проверки" class="qr-image" />
      </a>
    </div>
    
    <div class="footer">
      <p>Данное свидетельство подтверждает факт существования произведения на указанную дату.</p>
      <p>Цифровой отпечаток позволяет однозначно идентифицировать оригинальный файл.</p>
      <p class="platform">${certificateData.labelFull} • сайт ${certificateData.platform}</p>
    </div>
  </div>
</body>
</html>`;

  // Сохраняем HTML как файл с правильной кодировкой для скачивания
  const fileName = `certificate_${depositId}.html`;
  const safeTitle = (track.title || "Без названия").replace(/[^a-zA-Zа-яА-ЯёЁ0-9\s]/g, '_').trim();
  const htmlBytes = new TextEncoder().encode(htmlContent);
  
  // Создаём Blob с правильным content-type
  const blob = new Blob([htmlBytes], { type: "text/html;charset=utf-8" });
  
  const { error: uploadError } = await supabase.storage
    .from("certificates")
    .upload(fileName, blob, {
      contentType: "text/html;charset=utf-8",
      cacheControl: "3600",
      upsert: true,
    });

  if (uploadError) {
    console.error("Error uploading certificate:", uploadError);
    throw new Error("Не удалось сохранить сертификат");
  }

  // URL сертификата (публичный — для открытия в браузере; ?download= для скачивания)
  const publicPath = `/storage/v1/object/public/certificates/${fileName}`;
  const downloadName = `Авторское_свидетельство_${safeTitle}.html`;
  return `${publicBase}${publicPath}?download=${encodeURIComponent(downloadName)}`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Получаем пользователя
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Не авторизован");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    // Клиент с JWT пользователя — для RLS (auth.uid() = user_id при INSERT/DELETE)
    const userSupabase = createClient(supabaseUrl, supabaseServiceKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    
    if (authError || !user) {
      throw new Error("Не авторизован");
    }

    const { trackId, method, authorData }: DepositRequest = await req.json();
    console.log(`Deposit request: track=${trackId}, method=${method}, user=${user.id}`);

    // Получаем трек (audio_url, master_audio_url, normalized_audio_url — любой доступный URL)
    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select(`
        id, title, audio_url, master_audio_url, normalized_audio_url, duration, created_at,
        performer_name, music_author, lyrics_author, user_id,
        genre:genres(name_ru)
      `)
      .eq("id", trackId)
      .eq("user_id", user.id)
      .single();

    // Получаем username отдельно
    const { data: profile } = await supabase
      .from("profiles")
      .select("username")
      .eq("user_id", user.id)
      .single();

    const username = profile?.username || "Unknown";

    // Используем данные автора из запроса или из трека
    const effectiveAuthorData = {
      performer_name: authorData?.performer_name || track?.performer_name || username,
      music_author: authorData?.music_author || track?.music_author || "",
      lyrics_author: authorData?.lyrics_author || track?.lyrics_author || "",
    };

    if (trackError || !track) {
      throw new Error("Трек не найден или не принадлежит вам");
    }

    // Fallback: файл может физически лежать в tracks/audio/{id}.mp3, но URL в БД пустой
    const baseUrl = supabaseUrl || "https://aimuza.ru";
    const audioUrl = track.audio_url || track.master_audio_url || track.normalized_audio_url
      || `${baseUrl}/storage/v1/object/public/tracks/audio/${trackId}.mp3`;

    // Проверяем существующее депонирование
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
      // Удаляем failed или processing записи (userSupabase для RLS)
      await userSupabase
        .from("track_deposits")
        .delete()
        .eq("id", existingDeposit.id);
    }

    // Получаем настройки
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

    // Проверяем баланс если платно
    if (price > 0) {
      const { data: userProfile, error: profileError } = await supabase
        .from("profiles")
        .select("balance")
        .eq("user_id", user.id)
        .single();

      console.log(`User balance check: balance=${userProfile?.balance}, price=${price}, error=${profileError?.message}`);

      if (!userProfile || userProfile.balance < price) {
        throw new Error(`Недостаточно средств. Требуется: ${price} ₽, баланс: ${userProfile?.balance || 0} ₽`);
      }

      // Списываем средства
      const newBalance = userProfile.balance - price;
      console.log(`Deducting balance: ${userProfile.balance} - ${price} = ${newBalance}`);
      
      const { error: updateError } = await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", user.id);
      
      if (updateError) {
        console.error("Balance update error:", updateError);
        throw new Error("Ошибка списания средств");
      }
      
      console.log(`Balance updated successfully for user ${user.id}`);
    } else {
      console.log(`Deposit is free for method ${method}`);
    }

    // Генерируем хеш аудио
    console.log("Generating audio hash...", { urlLen: audioUrl.length });
    const fileHash = await getAudioHash(audioUrl);
    
    // Генерируем хеш метаданных
    const metadataHash = await generateHash(JSON.stringify({
      title: track.title,
      performer: effectiveAuthorData.performer_name,
      musicAuthor: effectiveAuthorData.music_author,
      lyricsAuthor: effectiveAuthorData.lyrics_author,
      duration: track.duration,
      fileHash,
      timestamp: new Date().toISOString(),
    }));

    // Создаём запись депонирования (userSupabase для RLS: auth.uid() = user_id)
    const depositId = crypto.randomUUID();
    const { error: insertError } = await userSupabase
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
      const msg = insertError?.message || insertError?.details || "Не удалось создать запись депонирования";
      throw new Error(typeof msg === "string" ? msg : "Не удалось создать запись депонирования");
    }

    let result: {
      certificateUrl?: string;
      blockchainTxId?: string;
      externalDepositId?: string;
      externalCertificateUrl?: string;
    } = {};

    try {
      switch (method) {
        case "internal":
          // Внутренний реестр - просто сохраняем хеши
          result.certificateUrl = await generatePdfCertificate(
            supabase, track, fileHash, depositId, effectiveAuthorData
          );
          break;

        case "pdf":
          // Генерация PDF сертификата
          result.certificateUrl = await generatePdfCertificate(
            supabase, track, fileHash, depositId, effectiveAuthorData
          );
          break;

        case "blockchain":
          // OpenTimestamps
          result.blockchainTxId = await submitToOpenTimestamps(fileHash);
          result.certificateUrl = await generatePdfCertificate(
            supabase, track, fileHash, depositId, effectiveAuthorData
          );
          break;

        case "nris":
          const nrisResult = await submitToNris(
            track,
            fileHash,
            settingsMap.get("nris_api_key") || "",
            settingsMap.get("nris_api_url") || "https://api.nris.ru/v1"
          );
          result.externalDepositId = nrisResult.depositId;
          result.externalCertificateUrl = nrisResult.certificateUrl;
          break;

        case "irma":
          const irmaResult = await submitToIrma(
            track,
            fileHash,
            settingsMap.get("irma_api_key") || "",
            settingsMap.get("irma_api_url") || "https://api.irma.ru/v1"
          );
          result.externalDepositId = irmaResult.depositId;
          result.externalCertificateUrl = irmaResult.certificateUrl;
          break;
      }

      // Обновляем статус на completed (userSupabase для RLS)
      await userSupabase
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

      // Создаём уведомление (userSupabase для RLS)
      await userSupabase.from("notifications").insert({
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
      
      // Обновляем статус на failed (userSupabase для RLS)
      await userSupabase
        .from("track_deposits")
        .update({
          status: "failed",
          error_message: error.message || "Unknown error",
        })
        .eq("id", depositId);

      // Возвращаем средства если были списаны
      if (price > 0) {
        const { data: currentProfile } = await supabase
          .from("profiles")
          .select("balance")
          .eq("user_id", user.id)
          .single();
        
        if (currentProfile) {
          await supabase
            .from("profiles")
            .update({ balance: currentProfile.balance + price })
            .eq("user_id", user.id);
        }
      }

      throw error;
    }

  } catch (error: any) {
    console.error("Deposit error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
