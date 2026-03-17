interface CertificateAuthorData {
  performer_name: string;
  music_author: string;
  lyrics_author: string;
}

interface TrackForCertificate {
  title: string;
  [key: string]: unknown;
}

function escapeHtml(value: string | null | undefined): string {
  return (value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export async function generatePdfCertificate(
  supabase: { storage: { from: (bucket: string) => { upload: (path: string, blob: Blob, opts: Record<string, string | boolean>) => Promise<{ error: unknown }> } } },
  track: TrackForCertificate,
  hash: string,
  depositId: string,
  authorData: CertificateAuthorData
): Promise<string> {
  const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  const safeTitle = (track.title || "Сертификат").replace(/[^a-zA-Zа-яА-ЯёЁ0-9\s]/g, "_").trim() || "Сертификат";
  const certificateUrl = `${baseUrl}/storage/v1/object/public/certificates/certificate_${depositId}.html`;
  const registryUrl = `${baseUrl}/registry/${encodeURIComponent(depositId)}`;
  const pdfFileName = `Авторское_свидетельство_${safeTitle}.pdf`;

  const certificateData = {
    trackTitle: escapeHtml(track.title),
    performer: escapeHtml(authorData.performer_name || "Не указан"),
    musicAuthor: escapeHtml(authorData.music_author || ""),
    lyricsAuthor: escapeHtml(authorData.lyrics_author || ""),
    fileHash: escapeHtml(hash),
    depositId: escapeHtml(depositId),
    platform: "aimuza.ru",
    label: 'ООО "Музыкальный лейбл НОТА-ФЕЯ"',
    pdfFileName: escapeHtml(pdfFileName),
  };

  const formattedDate = new Date().toLocaleString("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });

  const htmlContent = `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Сертификат депонирования - ${certificateData.trackTitle}</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/0.10.1/html2pdf.bundle.min.js"></script>
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
      max-width: 900px;
      margin: 0 auto;
      background: #fff;
      color: #1a1a1a;
      line-height: 1.5;
    }

    .actions {
      display: flex;
      flex-wrap: wrap;
      justify-content: center;
      gap: 12px;
      margin: 0 auto 20px;
    }

    .action-btn {
      padding: 12px 22px;
      background: #2c3e50;
      color: #fff;
      border: none;
      border-radius: 6px;
      font-size: 15px;
      cursor: pointer;
      font-family: inherit;
    }

    .action-btn.secondary {
      background: #465b70;
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

    .qr-corner {
      position: absolute;
      top: 22px;
      left: 22px;
      width: 78px;
      height: 78px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #fff;
      border: 1px solid #d8dee4;
      padding: 4px;
      z-index: 1;
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
      min-height: 48px;
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

    @media (max-width: 700px) {
      body { padding: 16px; }
      .certificate { padding: 24px; }
      .qr-corner {
        width: 64px;
        height: 64px;
        top: 16px;
        left: 16px;
      }
      .section { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="actions no-print">
    <button class="action-btn" onclick="downloadPdf()">Скачать PDF</button>
    <button class="action-btn secondary" onclick="window.print()">Распечатать</button>
  </div>

  <div class="certificate" id="certificate-root">
    <div class="qr-corner"><div id="qr-code"></div></div>
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

      <div class="section">
        <div class="label">Автор музыки:</div>
        <div class="value">${certificateData.musicAuthor}</div>
      </div>

      <div class="section">
        <div class="label">Автор текста:</div>
        <div class="value">${certificateData.lyricsAuthor}</div>
      </div>

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
      <div class="seal-text">НОТА-ФЕЯ<br/>Verified</div>
    </div>

    <div class="footer">
      <p>Данное свидетельство подтверждает факт существования произведения на указанную дату.</p>
      <p>Цифровой отпечаток позволяет однозначно идентифицировать оригинальный файл.</p>
      <p class="platform">${certificateData.label} • ${certificateData.platform}</p>
    </div>
  </div>

  <script>
    const registryUrl = ${JSON.stringify(registryUrl)};
    const pdfFileName = ${JSON.stringify(pdfFileName)};

    if (window.QRCode) {
      new QRCode(document.getElementById("qr-code"), {
        text: registryUrl,
        width: 68,
        height: 68,
        correctLevel: QRCode.CorrectLevel.M,
      });
    }

    async function downloadPdf() {
      const root = document.getElementById("certificate-root");
      if (!root || !window.html2pdf) {
        window.print();
        return;
      }

      await window.html2pdf().set({
        margin: 8,
        filename: pdfFileName,
        image: { type: "jpeg", quality: 0.98 },
        html2canvas: { scale: 2, useCORS: true, backgroundColor: "#ffffff" },
        jsPDF: { unit: "mm", format: "a4", orientation: "portrait" },
        pagebreak: { mode: ["avoid-all", "css", "legacy"] },
      }).from(root).save();
    }
  </script>
</body>
</html>`;

  const fileName = `certificate_${depositId}.html`;
  const htmlBytes = new TextEncoder().encode(htmlContent);
  const blob = new Blob([htmlBytes], { type: "text/html;charset=utf-8" });

  const { error: uploadError } = await supabase.storage
    .from("certificates")
    .upload(fileName, blob, {
      contentType: "text/html;charset=utf-8",
      cacheControl: "60",
      upsert: true,
    });

  if (uploadError) {
    console.error("Error uploading certificate:", uploadError);
    throw new Error("Не удалось сохранить сертификат");
  }

  return certificateUrl;
}
