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

export function generateCertificateHtml(track: TrackMetadata): string {
  const now = new Date();
  const formattedDate = now.toLocaleDateString('ru-RU', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });

  return `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>Сертификат авторства - ${track.title}</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@400;600;700&family=Montserrat:wght@300;400;600&display=swap');

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: 'Montserrat', sans-serif;
      background: linear-gradient(135deg, #0f0f23 0%, #1a1a3e 50%, #0f0f23 100%);
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
      padding: 40px;
    }

    .certificate {
      background: linear-gradient(180deg, #fefefe 0%, #f8f6f0 100%);
      border: 3px solid #c9a962;
      border-radius: 8px;
      padding: 60px 80px;
      max-width: 800px;
      width: 100%;
      position: relative;
      box-shadow: 0 20px 60px rgba(0,0,0,0.5);
    }

    .certificate::before {
      content: '';
      position: absolute;
      top: 15px;
      left: 15px;
      right: 15px;
      bottom: 15px;
      border: 1px solid #c9a962;
      border-radius: 4px;
      pointer-events: none;
    }

    .header {
      text-align: center;
      margin-bottom: 40px;
    }

    .logo {
      font-family: 'Cormorant Garamond', serif;
      font-size: 18px;
      color: #666;
      letter-spacing: 4px;
      text-transform: uppercase;
      margin-bottom: 20px;
    }

    .title {
      font-family: 'Cormorant Garamond', serif;
      font-size: 42px;
      font-weight: 700;
      color: #1a1a2e;
      margin-bottom: 10px;
    }

    .subtitle {
      font-size: 14px;
      color: #666;
      letter-spacing: 2px;
      text-transform: uppercase;
    }

    .divider {
      height: 2px;
      background: linear-gradient(90deg, transparent, #c9a962, transparent);
      margin: 30px 0;
    }

    .content {
      text-align: center;
    }

    .track-title {
      font-family: 'Cormorant Garamond', serif;
      font-size: 28px;
      font-weight: 600;
      color: #1a1a2e;
      margin-bottom: 15px;
    }

    .track-artist {
      font-size: 18px;
      color: #444;
      margin-bottom: 30px;
    }

    .info-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      margin: 30px 0;
      text-align: left;
    }

    .info-item {
      padding: 15px;
      background: rgba(201, 169, 98, 0.1);
      border-radius: 4px;
    }

    .info-label {
      font-size: 11px;
      color: #888;
      text-transform: uppercase;
      letter-spacing: 1px;
      margin-bottom: 5px;
    }

    .info-value {
      font-size: 14px;
      color: #1a1a2e;
      font-weight: 500;
    }

    .blockchain-section {
      margin: 40px 0;
      padding: 25px;
      background: #1a1a2e;
      border-radius: 6px;
      color: white;
    }

    .blockchain-title {
      font-size: 12px;
      color: #c9a962;
      text-transform: uppercase;
      letter-spacing: 2px;
      margin-bottom: 15px;
    }

    .blockchain-hash {
      font-family: 'Courier New', monospace;
      font-size: 11px;
      word-break: break-all;
      color: #8be9fd;
      background: rgba(0,0,0,0.3);
      padding: 15px;
      border-radius: 4px;
    }

    .footer {
      margin-top: 40px;
      text-align: center;
    }

    .seal {
      width: 100px;
      height: 100px;
      margin: 0 auto 20px;
      border: 3px solid #c9a962;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: 'Cormorant Garamond', serif;
      font-size: 12px;
      color: #c9a962;
      text-transform: uppercase;
      letter-spacing: 1px;
    }

    .date {
      font-size: 14px;
      color: #666;
    }

    .certificate-id {
      margin-top: 15px;
      font-size: 11px;
      color: #999;
      letter-spacing: 1px;
    }
  </style>
</head>
<body>
  <div class="certificate">
    <div class="header">
      <div class="logo">♪ Notafeya Records ♪</div>
      <h1 class="title">Сертификат Авторства</h1>
      <p class="subtitle">Certificate of Authorship</p>
    </div>

    <div class="divider"></div>

    <div class="content">
      <h2 class="track-title">"${track.title}"</h2>
      <p class="track-artist">Исполнитель: ${track.performer_name}</p>

      <div class="info-grid">
        <div class="info-item">
          <div class="info-label">Автор музыки</div>
          <div class="info-value">${track.music_author || track.performer_name}</div>
        </div>
        <div class="info-item">
          <div class="info-label">Автор текста</div>
          <div class="info-value">${track.lyrics_author || 'Инструментал'}</div>
        </div>
        <div class="info-item">
          <div class="info-label">ISRC код</div>
          <div class="info-value">${track.isrc_code || 'В обработке'}</div>
        </div>
        <div class="info-item">
          <div class="info-label">Лейбл</div>
          <div class="info-value">${track.label_name || 'Notafeya Records'}</div>
        </div>
      </div>

      <div class="blockchain-section">
        <div class="blockchain-title">⛓ Blockchain Verification</div>
        <div class="blockchain-hash">${track.blockchain_hash || 'Hash pending...'}</div>
      </div>
    </div>

    <div class="footer">
      <div class="seal">Verified<br/>✓</div>
      <p class="date">${formattedDate}</p>
      <p class="certificate-id">ID: ${track.id.substring(0, 8).toUpperCase()}</p>
    </div>
  </div>
</body>
</html>`;
}
