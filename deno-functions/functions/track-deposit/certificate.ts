interface CertificateAuthorData {
  performer_name: string;
  music_author: string;
  lyrics_author: string;
}

interface TrackForCertificate {
  title: string;
  [key: string]: unknown;
}

export async function generatePdfCertificate(
  supabase: { storage: { from: (bucket: string) => { upload: (path: string, blob: Blob, opts: Record<string, string>) => Promise<{ error: unknown }> } } },
  track: TrackForCertificate,
  hash: string,
  depositId: string,
  authorData: CertificateAuthorData
): Promise<string> {
  const certificateData = {
    title: "Авторское свидетельство",
    trackTitle: track.title,
    performer: authorData.performer_name || "Не указан",
    musicAuthor: authorData.music_author || "",
    lyricsAuthor: authorData.lyrics_author || "",
    fileHash: hash,
    depositId: depositId,
    depositDate: new Date().toISOString(),
    platform: "aimuza.ru",
    label: 'ООО "Музыкальный лейбл НОТА-ФЕЯ"',
  };

  const formattedDate = new Date(certificateData.depositDate).toLocaleString('ru-RU', {
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
  <button class="print-btn no-print" onclick="window.print()">Сохранить как PDF / Распечатать</button>
  
    <div class="certificate">
    <div class="header">
      <div class="logo-section">
        <div class="label-name">${certificateData.label}</div>
        <div class="website">${certificateData.platform}</div>
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
        <div class="seal-text">НОТА-ФЕЯ<br/>Verified</div>
      </div>
    </div>
    
    <div class="footer">
      <p>Данное свидетельство подтверждает факт существования произведения на указанную дату.</p>
      <p>Цифровой отпечаток позволяет однозначно идентифицировать оригинальный файл.</p>
      <p class="platform">${certificateData.label} • ${certificateData.platform}</p>
    </div>
  </div>
</body>
</html>`;

  const fileName = `certificate_${depositId}.html`;
  const safeTitle = track.title.replace(/[^a-zA-Zа-яА-ЯёЁ0-9\s]/g, '_').trim();
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

  const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  return `${BASE_URL}/storage/v1/object/public/certificates/${fileName}?download=Авторское_свидетельство_${encodeURIComponent(safeTitle)}.html`;
}
