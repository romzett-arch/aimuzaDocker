import type { TrackMetadata } from "./types.ts";

export function generateSilkXml(track: TrackMetadata): string {
  const now = new Date().toISOString();
  const releaseDate = track.processing_completed_at || now;
  const genreName = track.genre?.[0]?.name || 'Electronic';
  const genreNameRu = track.genre?.[0]?.name_ru || 'Электронная';
  const uploaderName = track.profiles?.[0]?.username || 'Unknown';

  return `<?xml version="1.0" encoding="UTF-8"?>
<release xmlns="http://silk.ru/schema/release/v1">
  <metadata>
    <format_version>1.0</format_version>
    <generated_at>${now}</generated_at>
    <generator>Notafeya Distribution Platform</generator>
  </metadata>

  <release_info>
    <internal_id>${track.id}</internal_id>
    <isrc>${track.isrc_code || 'PENDING'}</isrc>
    <title><![CDATA[${track.title}]]></title>
    <artist><![CDATA[${track.performer_name}]]></artist>
    <label><![CDATA[${track.label_name || 'Notafeya Records'}]]></label>
    <release_date>${releaseDate.split('T')[0]}</release_date>
    <genre>${genreName}</genre>
    <genre_ru>${genreNameRu}</genre_ru>
    <duration_seconds>${Math.round(track.duration || 0)}</duration_seconds>
  </release_info>

  <credits>
    <music_author><![CDATA[${track.music_author || track.performer_name}]]></music_author>
    <lyrics_author><![CDATA[${track.lyrics_author || 'Instrumental'}]]></lyrics_author>
    <performer><![CDATA[${track.performer_name}]]></performer>
    <producer><![CDATA[${track.performer_name}]]></producer>
    <uploader><![CDATA[${uploaderName}]]></uploader>
  </credits>

  <technical>
    <audio_format>WAV</audio_format>
    <bit_depth>24</bit_depth>
    <sample_rate>44100</sample_rate>
    <loudness_standard>-14 LUFS</loudness_standard>
    <mastered>true</mastered>
    <metadata_cleaned>true</metadata_cleaned>
  </technical>

  <blockchain>
    <hash>${track.blockchain_hash || 'N/A'}</hash>
    <timestamp>${releaseDate}</timestamp>
    <network>OpenTimestamps</network>
    <verified>true</verified>
  </blockchain>

  <assets>
    <master_audio>${track.master_audio_url ? 'included' : 'pending'}</master_audio>
    <cover_art resolution="3000x3000">${track.cover_url ? 'included' : 'pending'}</cover_art>
    <promo_video>not_available</promo_video>
    <certificate>${track.certificate_url ? 'included' : 'pending'}</certificate>
  </assets>

  <distribution>
    <platforms>
      <platform name="Spotify" status="ready"/>
      <platform name="Apple Music" status="ready"/>
      <platform name="Yandex Music" status="ready"/>
      <platform name="VK Music" status="ready"/>
      <platform name="Deezer" status="ready"/>
      <platform name="SoundCloud" status="ready"/>
    </platforms>
    <territory>Worldwide</territory>
    <exclusive>false</exclusive>
  </distribution>

  <legal>
    <copyright>© ${new Date().getFullYear()} ${track.label_name || 'Notafeya Records'}. All rights reserved.</copyright>
    <license>Standard Distribution License</license>
    <content_rating>Unrated</content_rating>
  </legal>
</release>`;
}

function escapeHtml(value: string | null | undefined): string {
  return (value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function generateCertificateHtml(track: TrackMetadata, registeredAt?: string): string {
  const certificateDate = registeredAt || track.processing_completed_at || track.created_at || new Date().toISOString();
  const formattedDate = new Date(certificateDate).toLocaleString("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const normalizedHash = (track.blockchain_hash || "").replace(/^0x/i, "");
  const trackTitle = escapeHtml(track.title);
  const performer = escapeHtml(track.performer_name || "Не указан");
  const musicAuthor = escapeHtml(track.music_author || "");
  const lyricsAuthor = escapeHtml(track.lyrics_author || "");
  const depositId = escapeHtml(track.id);
  const hashValue = escapeHtml(normalizedHash || "Не указан");

  return `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Сертификат депонирования - ${trackTitle}</title>
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
        <div class="label-name">ООО "Музыкальный лейбл НОТА-ФЕЯ"</div>
        <div class="website">aimuza.ru</div>
      </div>
      <div class="title">АВТОРСКОЕ СВИДЕТЕЛЬСТВО</div>
      <div class="subtitle">Музыкальное произведение</div>
    </div>

    <div class="content">
      <div class="section">
        <div class="label">Название произведения:</div>
        <div class="value">${trackTitle}</div>
      </div>

      <div class="section">
        <div class="label">Исполнитель:</div>
        <div class="value">${performer}</div>
      </div>

      <div class="section">
        <div class="label">Автор музыки:</div>
        <div class="value">${musicAuthor}</div>
      </div>

      <div class="section">
        <div class="label">Автор текста:</div>
        <div class="value">${lyricsAuthor}</div>
      </div>

      <div class="section">
        <div class="label">Цифровой отпечаток (SHA-256):</div>
        <div class="value hash">${hashValue}</div>
      </div>

      <div class="section">
        <div class="label">Идентификатор:</div>
        <div class="value">${depositId}</div>
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

    <div class="footer">
      <p>Данное свидетельство подтверждает факт существования произведения на указанную дату.</p>
      <p>Цифровой отпечаток позволяет однозначно идентифицировать оригинальный файл.</p>
      <p class="platform">ООО "Музыкальный лейбл НОТА-ФЕЯ" • aimuza.ru</p>
    </div>
  </div>
</body>
</html>`;
}
