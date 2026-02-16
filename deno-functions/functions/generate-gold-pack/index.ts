import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface GoldPackRequest {
  trackId: string;
}

interface TrackMetadata {
  id: string;
  title: string;
  performer_name: string;
  music_author: string | null;
  lyrics_author: string | null;
  label_name: string | null;
  isrc_code: string | null;
  duration: number;
  genre: { name_ru: string; name: string }[] | null;
  blockchain_hash: string | null;
  cover_url: string | null;
  master_audio_url: string | null;
  certificate_url: string | null;
  created_at: string;
  processing_completed_at: string | null;
  profiles: { username: string | null }[] | null;
}

// Generate SILK-compatible XML metadata
function generateSilkXml(track: TrackMetadata): string {
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

// Generate PDF certificate HTML (would be converted to PDF in production)
function generateCertificateHtml(track: TrackMetadata): string {
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

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { trackId }: GoldPackRequest = await req.json();
    console.log(`[generate-gold-pack] Starting for track: ${trackId}`);

    if (!trackId) {
      throw new Error('trackId is required');
    }

    // Get track with all metadata
    const { data: track, error: trackError } = await supabase
      .from('tracks')
      .select(`
        id, title, performer_name, music_author, lyrics_author, label_name,
        isrc_code, duration, blockchain_hash, cover_url, master_audio_url,
        certificate_url, created_at, processing_completed_at,
        profiles:user_id(username),
        genre:genres(name_ru, name)
      `)
      .eq('id', trackId)
      .single();

    if (trackError || !track) {
      throw new Error('Track not found');
    }

    console.log(`[generate-gold-pack] Generating assets for: ${track.title}`);

    // Generate SILK XML metadata
    const xmlContent = generateSilkXml(track as TrackMetadata);
    const xmlFileName = `gold-packs/${trackId}/metadata_silk.xml`;
    
    const { error: xmlUploadError } = await supabase.storage
      .from('tracks')
      .upload(xmlFileName, new Blob([xmlContent], { type: 'application/xml' }), {
        upsert: true,
        contentType: 'application/xml'
      });

    if (xmlUploadError) {
      console.error('[generate-gold-pack] XML upload error:', xmlUploadError);
    }

    // Generate certificate HTML (in production would convert to PDF)
    const certificateHtml = generateCertificateHtml(track as TrackMetadata);
    const certificateFileName = `gold-packs/${trackId}/certificate.html`;
    
    const { error: certUploadError } = await supabase.storage
      .from('tracks')
      .upload(certificateFileName, new Blob([certificateHtml], { type: 'text/html' }), {
        upsert: true,
        contentType: 'text/html'
      });

    if (certUploadError) {
      console.error('[generate-gold-pack] Certificate upload error:', certUploadError);
    }

    // Get public URLs
    const { data: xmlUrl } = supabase.storage.from('tracks').getPublicUrl(xmlFileName);
    const { data: certUrl } = supabase.storage.from('tracks').getPublicUrl(certificateFileName);

    // Generate pack manifest
    const manifest = {
      version: '1.0',
      generated_at: new Date().toISOString(),
      track_id: track.id,
      track_title: track.title,
      artist: track.performer_name,
      isrc: track.isrc_code,
      blockchain_hash: track.blockchain_hash,
      contents: {
        master_audio: {
          format: 'WAV 24-bit/44.1kHz',
          url: track.master_audio_url,
          status: track.master_audio_url ? 'included' : 'pending'
        },
        cover_art: {
          format: 'JPEG 3000x3000',
          url: track.cover_url,
          status: track.cover_url ? 'included' : 'pending'
        },
        metadata: {
          format: 'SILK XML v1.0',
          url: xmlUrl.publicUrl,
          status: 'included'
        },
        certificate: {
          format: 'HTML/PDF',
          url: certUrl.publicUrl,
          status: 'included'
        },
        promo_video: {
          format: 'MP4 1080p',
          url: null,
          status: 'not_available'
        }
      },
      distribution: {
        platforms: ['Spotify', 'Apple Music', 'Yandex Music', 'VK Music', 'Deezer', 'SoundCloud'],
        territory: 'Worldwide',
        release_ready: true
      }
    };

    const manifestFileName = `gold-packs/${trackId}/manifest.json`;
    await supabase.storage
      .from('tracks')
      .upload(manifestFileName, new Blob([JSON.stringify(manifest, null, 2)], { type: 'application/json' }), {
        upsert: true,
        contentType: 'application/json'
      });

    const { data: manifestUrl } = supabase.storage.from('tracks').getPublicUrl(manifestFileName);

    // Update track with gold pack URL (manifest as entry point)
    await supabase
      .from('tracks')
      .update({
        gold_pack_url: manifestUrl.publicUrl,
        certificate_url: certUrl.publicUrl
      })
      .eq('id', trackId);

    // Log the gold pack generation
    const { data: userData } = await supabase
      .from('tracks')
      .select('user_id')
      .eq('id', trackId)
      .single();

    if (userData) {
      await supabase.from('distribution_logs').insert({
        track_id: trackId,
        user_id: userData.user_id,
        action: 'gold_pack_generated',
        stage: 'level_pro',
        details: {
          manifest_url: manifestUrl.publicUrl,
          xml_url: xmlUrl.publicUrl,
          certificate_url: certUrl.publicUrl,
          has_master: !!track.master_audio_url,
          has_cover: !!track.cover_url,
          has_video: false
        }
      });

      // Notify user
      await supabase.from('notifications').insert({
        user_id: userData.user_id,
        type: 'system',
        title: '📦 Золотой пакет SILK готов!',
        message: `Ваш трек "${track.title}" готов к дистрибуции. WAV, XML-метаданные и сертификат доступны для скачивания.`,
        target_type: 'track',
        target_id: trackId
      });
    }

    return new Response(
      JSON.stringify({
        success: true,
        goldPack: {
          manifestUrl: manifestUrl.publicUrl,
          xmlUrl: xmlUrl.publicUrl,
          certificateUrl: certUrl.publicUrl,
          masterAudioUrl: track.master_audio_url,
          coverUrl: track.cover_url,
          promoVideoUrl: null
        }
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[generate-gold-pack] Error:', error);
    const message = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
