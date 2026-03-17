import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./types.ts";
import type { GoldPackRequest, TrackMetadata } from "./types.ts";
import { generateSilkXml, generateCertificateHtml } from "./generators.ts";

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { trackId, registeredAt }: GoldPackRequest = await req.json();
    console.log(`[generate-gold-pack] Starting for track: ${trackId}`);

    if (!trackId) {
      throw new Error('trackId is required');
    }

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

    const certificateHtml = generateCertificateHtml(track as TrackMetadata, registeredAt);
    const certificateFileName = `gold-packs/${trackId}/certificate.html`;

    const { error: certUploadError } = await supabase.storage
      .from('tracks')
      .upload(certificateFileName, new Blob([certificateHtml], { type: 'text/html;charset=utf-8' }), {
        upsert: true,
        contentType: 'text/html;charset=utf-8'
      });

    if (certUploadError) {
      console.error('[generate-gold-pack] Certificate upload error:', certUploadError);
    }

    const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    const xmlPublicUrl = `${BASE_URL}/storage/v1/object/public/tracks/${xmlFileName}`;
    const certPublicUrl = `${BASE_URL}/storage/v1/object/public/tracks/${certificateFileName}`;

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
          url: xmlPublicUrl,
          status: 'included'
        },
        certificate: {
          format: 'HTML/PDF',
          url: certPublicUrl,
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

    const manifestPublicUrl = `${BASE_URL}/storage/v1/object/public/tracks/${manifestFileName}`;

    await supabase
      .from('tracks')
      .update({
        gold_pack_url: manifestPublicUrl,
        certificate_url: certPublicUrl
      })
      .eq('id', trackId);

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
          manifest_url: manifestPublicUrl,
          xml_url: xmlPublicUrl,
          certificate_url: certPublicUrl,
          has_master: !!track.master_audio_url,
          has_cover: !!track.cover_url,
          has_video: false
        }
      });

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
          manifestUrl: manifestPublicUrl,
          xmlUrl: xmlPublicUrl,
          certificateUrl: certPublicUrl,
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
