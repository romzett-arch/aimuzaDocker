import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface DepositRequest {
  lyricsId: string;
  method: "internal" | "blockchain" | "nris" | "irma";
  authorName?: string;
}

// Генерация SHA-256 хеша
async function generateHash(data: string): Promise<string> {
  const encoder = new TextEncoder();
  const dataBuffer = encoder.encode(data);
  const hashBuffer = await crypto.subtle.digest("SHA-256", dataBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

// OpenTimestamps - бесплатная blockchain фиксация
async function submitToOpenTimestamps(hash: string): Promise<string> {
  try {
    const response = await fetch("https://a.pool.opentimestamps.org/digest", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: hash,
    });
    
    if (!response.ok) {
      const fallbackResponse = await fetch("https://b.pool.opentimestamps.org/digest", {
        method: "POST", 
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: hash,
      });
      
      if (!fallbackResponse.ok) {
        throw new Error("OpenTimestamps servers unavailable");
      }
      return `ots_pending_${Date.now()}`;
    }
    return `ots_${Date.now()}`;
  } catch (error) {
    console.error("OpenTimestamps error:", error);
    return `ots_pending_${hash.substring(0, 16)}`;
  }
}

// n'RIS API интеграция
async function submitToNris(
  lyrics: any,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ n'RIS не настроен");
  }

  const response = await fetch(`${apiUrl}/deposits`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      type: "lyrics",
      title: lyrics.title,
      author: lyrics.author_name,
      hash: hash,
      metadata: {
        created_at: lyrics.created_at,
        language: lyrics.language,
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
}

// IRMA API интеграция
async function submitToIrma(
  lyrics: any,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ IRMA не настроен");
  }

  const response = await fetch(`${apiUrl}/register`, {
    method: "POST",
    headers: {
      "X-API-Key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      work_type: "lyrics",
      title: lyrics.title,
      creators: [{ role: "author", name: lyrics.author_name }],
      content_hash: hash,
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
}

// Генерация HTML сертификата для текста
async function generateLyricsCertificate(
  supabase: any,
  lyrics: any,
  hash: string,
  depositId: string,
  authorName: string
): Promise<string> {
  const formattedDate = new Date().toLocaleString('ru-RU', {
    day: '2-digit',
    month: '2-digit', 
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  });

  const htmlContent = `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Сертификат депонирования текста - ${lyrics.title}</title>
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
      top: 10px; left: 10px; right: 10px; bottom: 10px;
      border: 1px solid #bdc3c7;
      pointer-events: none;
    }
    .header { 
      text-align: center; 
      border-bottom: 2px solid #2c3e50; 
      padding-bottom: 25px; 
      margin-bottom: 30px; 
    }
    .label-name { font-size: 14px; color: #555; font-weight: 500; letter-spacing: 1px; margin-bottom: 5px; }
    .website { font-size: 18px; color: #2c3e50; font-weight: bold; letter-spacing: 2px; }
    .title { 
      font-size: 28px; font-weight: bold; color: #1a1a1a; 
      text-transform: uppercase; letter-spacing: 3px; margin-top: 20px;
    }
    .subtitle { font-size: 16px; color: #666; margin-top: 10px; font-style: italic; }
    .content { display: grid; gap: 18px; }
    .section { display: grid; grid-template-columns: 180px 1fr; align-items: start; gap: 15px; }
    .label { font-weight: bold; color: #2c3e50; font-size: 14px; padding-top: 10px; }
    .value { 
      padding: 12px 15px; background: #fff; border: 1px solid #ddd;
      border-radius: 4px; font-size: 15px; box-shadow: inset 0 1px 3px rgba(0,0,0,0.05);
    }
    .hash { font-family: 'Courier New', monospace; font-size: 11px; word-break: break-all; color: #555; }
    .seal { text-align: center; margin: 35px 0 25px; }
    .seal-text { 
      display: inline-block; padding: 20px 35px; border: 4px double #2c3e50; 
      border-radius: 50%; font-size: 14px; font-weight: bold; color: #2c3e50;
      text-align: center; line-height: 1.4; background: linear-gradient(135deg, #fff 0%, #f0f0f0 100%);
    }
    .footer { 
      margin-top: 30px; padding-top: 20px; border-top: 2px solid #2c3e50; 
      font-size: 12px; color: #666; text-align: center; line-height: 1.8;
    }
    .footer .platform { font-weight: bold; color: #2c3e50; font-size: 14px; margin-top: 15px; }
    .print-btn {
      display: block; margin: 20px auto; padding: 12px 30px;
      background: #2c3e50; color: #fff; border: none; border-radius: 5px;
      font-size: 16px; cursor: pointer; font-family: inherit;
    }
    .print-btn:hover { background: #1a252f; }
  </style>
</head>
<body>
  <button class="print-btn no-print" onclick="window.print()">📄 Сохранить как PDF / Распечатать</button>
  
  <div class="certificate">
    <div class="header">
      <div class="label-name">ООО "Музыкальный лейбл НОТА-ФЕЯ"</div>
      <div class="website">aimuza.ru</div>
      <div class="title">СЕРТИФИКАТ ДЕПОНИРОВАНИЯ</div>
      <div class="subtitle">Литературное произведение (текст песни)</div>
    </div>
    
    <div class="content">
      <div class="section">
        <div class="label">Название:</div>
        <div class="value">${lyrics.title}</div>
      </div>
      <div class="section">
        <div class="label">Автор текста:</div>
        <div class="value">${authorName || "Не указан"}</div>
      </div>
      <div class="section">
        <div class="label">Цифровой отпечаток (SHA-256):</div>
        <div class="value hash">${hash}</div>
      </div>
      <div class="section">
        <div class="label">Идентификатор:</div>
        <div class="value">${depositId}</div>
      </div>
      <div class="section">
        <div class="label">Дата депонирования:</div>
        <div class="value">${formattedDate}</div>
      </div>
    </div>
    
    <div class="seal">
      <div class="seal-text">НОТА-ФЕЯ<br/>✓ Verified</div>
    </div>
    
    <div class="footer">
      <p>Данный сертификат подтверждает факт существования текста на указанную дату.</p>
      <p>Цифровой отпечаток позволяет однозначно идентифицировать оригинальный текст.</p>
      <p class="platform">ООО "Музыкальный лейбл НОТА-ФЕЯ" • aimuza.ru</p>
    </div>
  </div>
</body>
</html>`;

  const fileName = `lyrics_certificate_${depositId}.html`;
  const htmlBytes = new TextEncoder().encode(htmlContent);
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

  const { data: urlData } = supabase.storage
    .from("certificates")
    .getPublicUrl(fileName);

  return urlData.publicUrl;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get user from auth header
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

    // Get lyrics data
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

    // Check for existing deposit
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

    // Get deposit price
    const { data: priceSetting } = await supabase
      .from("app_settings")
      .select("value")
      .eq("key", "lyrics_deposit_price")
      .single();
    
    const depositPrice = parseInt(priceSetting?.value || "50", 10);

    // Check user balance
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

    // Generate hash from lyrics content
    const contentHash = await generateHash(lyrics.content + lyrics.title + new Date().toISOString());
    const timestampHash = await generateHash(contentHash + Date.now().toString());

    let externalId: string | null = null;
    let certificateUrl: string | null = null;

    // Process based on method
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

    // Generate internal deposit ID
    const depositId = `LYR-${Date.now()}-${Math.random().toString(36).substr(2, 9).toUpperCase()}`;
    
    // Always generate PDF certificate for internal
    if (method === "internal" || !certificateUrl) {
      certificateUrl = await generateLyricsCertificate(
        supabase,
        lyrics,
        contentHash,
        depositId,
        authorName || ""
      );
    }

    // Deduct balance
    await supabase
      .from("profiles")
      .update({ balance: (profile.balance || 0) - depositPrice })
      .eq("user_id", user.id);

    // Create deposit record
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
      // Refund on error
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user.id);
      throw depositError;
    }

    // Create notification
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
