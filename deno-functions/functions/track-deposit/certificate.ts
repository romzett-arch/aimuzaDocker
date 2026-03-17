import QRCode from "npm:qrcode@1.5.4";
import { generateHashFromBytes } from "./utils.ts";

interface CertificateAuthorData {
  performer_name: string;
  music_author: string;
  lyrics_author: string;
}

interface TrackForCertificate {
  title: string;
  [key: string]: unknown;
}

interface CertificateBlockchainData {
  blockchainTxId?: string | null;
  blockchainProofUrl?: string | null;
  blockchainProofStatus?: string | null;
  blockchainSubmittedAt?: string | null;
}

export interface CertificateArtifactsResult {
  certificateUrl: string;
  pdfUrl: string;
  registryUrl: string;
  certificateHtmlHash: string;
  certificatePdfHash: string;
  certificateGeneratedAt: string;
}

function escapeHtml(value: string | null | undefined): string {
  return (value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function buildStorageUrl(baseUrl: string, fileName: string): string {
  return `${baseUrl}/storage/v1/object/public/certificates/${fileName}`;
}

async function renderPdfWithGotenberg(htmlContent: string): Promise<Uint8Array> {
  const gotenbergUrl = Deno.env.get("GOTENBERG_URL") || "http://gotenberg:3000";
  const formData = new FormData();
  formData.append(
    "files",
    new Blob([new TextEncoder().encode(htmlContent)], { type: "text/html;charset=utf-8" }),
    "index.html",
  );
  formData.append("preferCssPageSize", "true");
  formData.append("printBackground", "true");

  const response = await fetch(`${gotenbergUrl}/forms/chromium/convert/html`, {
    method: "POST",
    body: formData,
  });

  if (!response.ok) {
    const errorText = await response.text().catch(() => "");
    console.error("Gotenberg error:", response.status, errorText);
    throw new Error("Не удалось сгенерировать PDF сертификата");
  }

  return new Uint8Array(await response.arrayBuffer());
}

async function buildQrSvg(registryUrl: string): Promise<string> {
  return QRCode.toString(registryUrl, {
    type: "svg",
    margin: 0,
    width: 68,
    color: {
      dark: "#1a1a1a",
      light: "#ffffff",
    },
  });
}

function buildCertificateHtml(params: {
  authorData: CertificateAuthorData;
  blockchain: CertificateBlockchainData;
  depositId: string;
  fileHash: string;
  formattedDate: string;
  pdfUrl: string;
  proofUrl: string | null;
  qrSvg: string;
  registryUrl: string;
  title: string;
}): string {
  const certificateData = {
    trackTitle: escapeHtml(params.title),
    performer: escapeHtml(params.authorData.performer_name || "Не указан"),
    musicAuthor: escapeHtml(params.authorData.music_author || "Не указан"),
    lyricsAuthor: escapeHtml(params.authorData.lyrics_author || "Не указан"),
    fileHash: escapeHtml(params.fileHash),
    depositId: escapeHtml(params.depositId),
    registryUrl: escapeHtml(params.registryUrl),
    pdfUrl: escapeHtml(params.pdfUrl),
    proofUrl: escapeHtml(params.proofUrl),
    formattedDate: escapeHtml(params.formattedDate),
    platform: "aimuza.ru",
    label: 'ООО "Музыкальный лейбл НОТА-ФЕЯ"',
  };

  return `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Сертификат депонирования - ${certificateData.trackTitle}</title>
  <style>
    @page { size: A4; margin: 10mm; }
    @media print {
      body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      .no-print { display: none !important; }
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: "Times New Roman", Georgia, serif;
      padding: 24px;
      max-width: 900px;
      margin: 0 auto;
      background: #fff;
      color: #1a1a1a;
      line-height: 1.45;
    }

    a {
      color: #2c3e50;
      text-decoration: underline;
    }

    .actions {
      display: flex;
      flex-wrap: wrap;
      justify-content: center;
      gap: 12px;
      margin: 0 auto 14px;
    }

    .action-link {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      padding: 12px 22px;
      background: #2c3e50;
      color: #fff;
      border-radius: 6px;
      font-size: 15px;
      text-decoration: none;
    }

    .action-link.secondary {
      background: #465b70;
    }

    .certificate {
      border: 3px double #2c3e50;
      padding: 30px;
      background: linear-gradient(135deg, #fefefe 0%, #f8f9fa 100%);
      position: relative;
    }

    .certificate::before {
      content: "";
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
      padding-bottom: 22px;
      margin-bottom: 24px;
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

    .qr-corner svg {
      display: block;
      width: 68px;
      height: 68px;
    }

    .logo-section {
      margin-bottom: 12px;
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
      font-size: 30px;
      font-weight: bold;
      color: #1a1a1a;
      text-transform: uppercase;
      letter-spacing: 3px;
      margin-top: 18px;
    }

    .subtitle {
      font-size: 16px;
      color: #666;
      margin-top: 10px;
      font-style: italic;
    }

    .content {
      display: grid;
      gap: 14px;
    }

    .section {
      display: grid;
      grid-template-columns: 160px 1fr;
      align-items: start;
      gap: 12px;
    }

    .label {
      font-weight: bold;
      color: #2c3e50;
      font-size: 14px;
      padding-top: 9px;
    }

    .value {
      padding: 11px 14px;
      background: #fff;
      border: 1px solid #ddd;
      border-radius: 4px;
      font-size: 15px;
      box-shadow: inset 0 1px 3px rgba(0, 0, 0, 0.05);
      min-height: 45px;
    }

    .hash {
      font-family: "Courier New", monospace;
      font-size: 10.5px;
      word-break: break-all;
      color: #555;
      letter-spacing: 0.3px;
    }

    .seal {
      text-align: center;
      margin: 28px 0 20px;
    }

    .seal-text {
      display: inline-block;
      padding: 16px 30px;
      border: 4px double #2c3e50;
      border-radius: 50%;
      font-size: 13px;
      font-weight: bold;
      color: #2c3e50;
      text-align: center;
      line-height: 1.4;
      background: linear-gradient(135deg, #fff 0%, #f0f0f0 100%);
    }

    .footer {
      margin-top: 22px;
      padding-top: 16px;
      border-top: 2px solid #2c3e50;
      font-size: 11.5px;
      color: #666;
      text-align: center;
      line-height: 1.6;
    }

    .footer p {
      margin: 4px 0;
    }

    .footer .platform {
      font-weight: bold;
      color: #2c3e50;
      font-size: 14px;
      margin-top: 12px;
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
      .qr-corner svg {
        width: 56px;
        height: 56px;
      }
      .section { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="actions no-print">
    <a class="action-link" href="${certificateData.pdfUrl}" target="_blank" rel="noopener noreferrer">Скачать PDF</a>
    <a class="action-link secondary" href="${certificateData.registryUrl}" target="_blank" rel="noopener noreferrer">Запись реестра</a>
    ${params.proofUrl ? `<a class="action-link secondary" href="${certificateData.proofUrl}" target="_blank" rel="noopener noreferrer">Proof (.ots)</a>` : ""}
  </div>

  <div class="certificate">
    <div class="qr-corner">${params.qrSvg}</div>
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
        <div class="value">${certificateData.formattedDate}</div>
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
</body>
</html>`;
}

export async function generatePdfCertificate(
  supabase: {
    storage: {
      from: (
        bucket: string,
      ) => {
        upload: (
          path: string,
          blob: Blob,
          opts: Record<string, string | boolean>,
        ) => Promise<{ error: unknown }>;
      };
    };
  },
  track: TrackForCertificate,
  hash: string,
  depositId: string,
  authorData: CertificateAuthorData,
  blockchain: CertificateBlockchainData = {},
): Promise<CertificateArtifactsResult> {
  const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  const certificateFileName = `certificate_${depositId}.html`;
  const pdfFileName = `certificate_${depositId}.pdf`;
  const certificateUrl = buildStorageUrl(baseUrl, certificateFileName);
  const pdfUrl = buildStorageUrl(baseUrl, pdfFileName);
  const registryUrl = `${baseUrl}/registry/${encodeURIComponent(depositId)}`;
  const generatedAt = new Date().toISOString();
  const formattedDate = `${new Date(generatedAt).toLocaleString("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })}`;
  const qrSvg = await buildQrSvg(registryUrl);
  const htmlContent = buildCertificateHtml({
    authorData,
    blockchain,
    depositId,
    fileHash: hash,
    formattedDate,
    pdfUrl,
    proofUrl: blockchain.blockchainProofUrl ?? null,
    qrSvg,
    registryUrl,
    title: track.title || "Сертификат",
  });

  const htmlBytes = new TextEncoder().encode(htmlContent);
  const pdfBytes = await renderPdfWithGotenberg(htmlContent);

  const { error: htmlUploadError } = await supabase.storage
    .from("certificates")
    .upload(certificateFileName, new Blob([htmlBytes], { type: "text/html;charset=utf-8" }), {
      contentType: "text/html;charset=utf-8",
      cacheControl: "0",
      upsert: true,
    });

  if (htmlUploadError) {
    console.error("Error uploading HTML certificate:", htmlUploadError);
    throw new Error("Не удалось сохранить HTML сертификат");
  }

  const { error: pdfUploadError } = await supabase.storage
    .from("certificates")
    .upload(pdfFileName, new Blob([pdfBytes], { type: "application/pdf" }), {
      contentType: "application/pdf",
      cacheControl: "31536000",
      upsert: true,
    });

  if (pdfUploadError) {
    console.error("Error uploading PDF certificate:", pdfUploadError);
    throw new Error("Не удалось сохранить PDF сертификат");
  }

  return {
    certificateUrl,
    pdfUrl,
    registryUrl,
    certificateHtmlHash: await generateHashFromBytes(htmlBytes),
    certificatePdfHash: await generateHashFromBytes(pdfBytes),
    certificateGeneratedAt: generatedAt,
  };
}
