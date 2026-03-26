import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import JSZip from "npm:jszip@3.10.1";
import { corsHeaders } from "./types.ts";
import type { GoldPackRequest, TrackMetadata } from "./types.ts";
import { generateSilkXml, generateCertificateHtml } from "./generators.ts";

const TRACKS_BUCKET = "tracks";
const DEFAULT_BASE_URL = "https://aimuza.ru";
const DEFAULT_PLATFORMS = [
  "Spotify",
  "Apple Music",
  "Yandex Music",
  "VK Music",
  "Deezer",
  "SoundCloud",
];

function buildPublicUrl(baseUrl: string, fileName: string): string {
  return `${baseUrl}/storage/v1/object/public/${TRACKS_BUCKET}/${fileName}`;
}

function inferFileExtension(rawUrl: string | null | undefined, fallback: string): string {
  if (!rawUrl) return fallback;

  try {
    const pathname = new URL(rawUrl, DEFAULT_BASE_URL).pathname;
    const cleanPathname = pathname.split("?")[0] ?? pathname;
    const parts = cleanPathname.split(".");
    const ext = parts.length > 1 ? parts.at(-1)?.toLowerCase() : "";
    return ext ? `.${ext}` : fallback;
  } catch {
    return fallback;
  }
}

function toStorageFetchUrl(rawUrl: string, storageOrigin: string): string {
  const normalizedStorageOrigin = storageOrigin.replace(/\/$/, "");
  const target = new URL(rawUrl, normalizedStorageOrigin);

  if (target.pathname.startsWith("/storage/v1/object/public/")) {
    return `${normalizedStorageOrigin}${target.pathname}${target.search}`;
  }

  return target.toString();
}

async function fetchAssetBytes(rawUrl: string, label: string, storageOrigin: string): Promise<Uint8Array> {
  const response = await fetch(toStorageFetchUrl(rawUrl, storageOrigin));
  if (!response.ok) {
    throw new Error(`${label}: asset_download_failed (${response.status})`);
  }

  return new Uint8Array(await response.arrayBuffer());
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
    console.error("[generate-gold-pack] Gotenberg error:", response.status, errorText);
    throw new Error("certificate_pdf_generation_failed");
  }

  return new Uint8Array(await response.arrayBuffer());
}

async function uploadBytes(
  supabase: ReturnType<typeof createClient>,
  fileName: string,
  bytes: Uint8Array,
  contentType: string,
) {
  const { error } = await supabase.storage
    .from(TRACKS_BUCKET)
    .upload(fileName, new Blob([bytes], { type: contentType }), {
      upsert: true,
      contentType,
      cacheControl: "0",
    });

  if (error) {
    throw new Error(`${fileName}: ${error.message}`);
  }
}

async function ensureIsrcCode(
  supabase: ReturnType<typeof createClient>,
  trackId: string,
  currentIsrc: string | null | undefined,
): Promise<string> {
  if (currentIsrc) {
    return currentIsrc;
  }

  const year = new Date().getFullYear().toString().slice(-2);

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const randomPart = crypto.getRandomValues(new Uint32Array(1))[0] % 100000;
    const candidate = `RUNFA${year}${randomPart.toString().padStart(5, "0")}`;

    const { error } = await supabase
      .from("tracks")
      .update({ isrc_code: candidate })
      .eq("id", trackId)
      .is("isrc_code", null);

    if (!error) {
      return candidate;
    }
  }

  const { data: refreshedTrack, error: refreshError } = await supabase
    .from("tracks")
    .select("isrc_code")
    .eq("id", trackId)
    .single();

  if (refreshError || !refreshedTrack?.isrc_code) {
    throw new Error("isrc_generation_failed");
  }

  return refreshedTrack.isrc_code;
}

function getMissingRequiredAssets(track: TrackMetadata): string[] {
  const missing: string[] = [];

  if (!track.master_audio_url) missing.push("master_audio");
  if (!track.cover_url) missing.push("cover_art");
  if (!track.blockchain_hash) missing.push("blockchain_hash");
  if (!track.isrc_code) missing.push("isrc_code");

  return missing;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { trackId, registeredAt, finalizeTrack = true }: GoldPackRequest = await req.json();
    if (!trackId) {
      throw new Error("trackId is required");
    }

    const baseUrl = Deno.env.get("BASE_URL") || DEFAULT_BASE_URL;
    const storageOrigin = Deno.env.get("SUPABASE_URL") || baseUrl;

    const { data: trackData, error: trackError } = await supabase
      .from("tracks")
      .select(`
        id, title, performer_name, music_author, lyrics_author, label_name,
        isrc_code, duration, blockchain_hash, cover_url, master_audio_url,
        normalized_audio_url, certificate_url, created_at, processing_completed_at,
        distribution_status,
        profiles:user_id(username),
        genre:genres(name_ru, name)
      `)
      .eq("id", trackId)
      .single();

    if (trackError || !trackData) {
      throw new Error("Track not found");
    }

    const isrcCode = await ensureIsrcCode(supabase, trackId, trackData.isrc_code);
    const track = {
      ...trackData,
      isrc_code: isrcCode,
      master_audio_url: trackData.master_audio_url || trackData.normalized_audio_url || null,
    } as TrackMetadata;

    const missingRequiredAssets = getMissingRequiredAssets(track);
    if (missingRequiredAssets.length > 0) {
      throw new Error(`missing_required_assets:${missingRequiredAssets.join(",")}`);
    }

    const proofFileName = `gold-packs/${trackId}/proof.ots`;
    const xmlFileName = `gold-packs/${trackId}/metadata_silk.xml`;
    const certificateHtmlFileName = `gold-packs/${trackId}/certificate.html`;
    const certificatePdfFileName = `gold-packs/${trackId}/certificate.pdf`;
    const packageZipFileName = `gold-packs/${trackId}/gold-pack.zip`;
    const manifestFileName = `gold-packs/${trackId}/manifest.json`;

    const xmlPublicUrl = buildPublicUrl(baseUrl, xmlFileName);
    const certificateHtmlUrl = buildPublicUrl(baseUrl, certificateHtmlFileName);
    const certificatePdfUrl = buildPublicUrl(baseUrl, certificatePdfFileName);
    const proofPublicUrl = buildPublicUrl(baseUrl, proofFileName);
    const zipPublicUrl = buildPublicUrl(baseUrl, packageZipFileName);
    const manifestPublicUrl = buildPublicUrl(baseUrl, manifestFileName);

    const latestPromoVideoResponse = await supabase
      .from("promo_videos")
      .select("video_url, completed_at")
      .eq("track_id", trackId)
      .eq("status", "completed")
      .not("video_url", "is", null)
      .order("completed_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const promoVideoUrl = latestPromoVideoResponse.data?.video_url || null;

    const enrichedTrack: TrackMetadata = {
      ...track,
      certificate_url: certificateHtmlUrl,
    };

    const xmlContent = generateSilkXml(enrichedTrack);
    const certificateHtml = generateCertificateHtml(enrichedTrack, registeredAt);
    const pdfBytes = await renderPdfWithGotenberg(certificateHtml);
    const xmlBytes = new TextEncoder().encode(xmlContent);
    const htmlBytes = new TextEncoder().encode(certificateHtml);

    await uploadBytes(supabase, xmlFileName, xmlBytes, "application/xml");
    await uploadBytes(supabase, certificateHtmlFileName, htmlBytes, "text/html;charset=utf-8");
    await uploadBytes(supabase, certificatePdfFileName, pdfBytes, "application/pdf");

    const masterBytes = await fetchAssetBytes(track.master_audio_url!, "master_audio", storageOrigin);
    const coverBytes = await fetchAssetBytes(track.cover_url!, "cover_art", storageOrigin);

    let proofBytes: Uint8Array | null = null;
    try {
      proofBytes = await fetchAssetBytes(proofPublicUrl, "proof_ots", storageOrigin);
    } catch (error) {
      console.warn("[generate-gold-pack] Proof file not available:", error);
    }

    let promoVideoBytes: Uint8Array | null = null;
    if (promoVideoUrl) {
      try {
        promoVideoBytes = await fetchAssetBytes(promoVideoUrl, "promo_video", storageOrigin);
      } catch (error) {
        console.warn("[generate-gold-pack] Promo video skipped:", error);
      }
    }

    const manifest = {
      version: "2.0",
      generated_at: new Date().toISOString(),
      track_id: track.id,
      track_title: track.title,
      artist: track.performer_name,
      isrc: isrcCode,
      blockchain_hash: track.blockchain_hash,
      contents: {
        master_audio: {
          file_name: "master.wav",
          format: "WAV 24-bit/44.1kHz",
          url: track.master_audio_url,
          status: "included",
        },
        cover_art: {
          file_name: `cover_3000x3000${inferFileExtension(track.cover_url, ".jpg")}`,
          format: "JPEG/PNG 3000x3000",
          url: track.cover_url,
          status: "included",
        },
        metadata: {
          file_name: "metadata.xml",
          format: "SILK XML v1.0",
          url: xmlPublicUrl,
          status: "included",
        },
        certificate_html: {
          file_name: "certificate.html",
          format: "HTML",
          url: certificateHtmlUrl,
          status: "included",
        },
        certificate_pdf: {
          file_name: "certificate.pdf",
          format: "PDF",
          url: certificatePdfUrl,
          status: "included",
        },
        proof_ots: {
          file_name: "proof.ots",
          format: "OpenTimestamps",
          url: proofBytes ? proofPublicUrl : null,
          status: proofBytes ? "included" : "not_available",
        },
        promo_video: {
          file_name: "promo_video.mp4",
          format: "MP4 1080p",
          url: promoVideoBytes ? promoVideoUrl : null,
          status: promoVideoBytes ? "included" : "not_available",
        },
        package_zip: {
          file_name: "gold-pack.zip",
          format: "ZIP",
          url: zipPublicUrl,
          status: "pending",
        },
      },
      distribution: {
        platforms: DEFAULT_PLATFORMS,
        territory: "Worldwide",
        release_ready: true,
        missing_required_assets: [] as string[],
      },
    };

    const zip = new JSZip();
    zip.file("master.wav", masterBytes);
    zip.file("metadata.xml", xmlBytes);
    zip.file("certificate.html", htmlBytes);
    zip.file("certificate.pdf", pdfBytes);
    zip.file(manifest.contents.cover_art.file_name, coverBytes);
    zip.file("manifest.json", JSON.stringify(manifest, null, 2));

    if (proofBytes) {
      zip.file("proof.ots", proofBytes);
    }

    if (promoVideoBytes) {
      zip.file("promo_video.mp4", promoVideoBytes);
    }

    const zipBytes = await zip.generateAsync({
      type: "uint8array",
      compression: "DEFLATE",
      compressionOptions: { level: 6 },
    });

    manifest.contents.package_zip.status = "included";
    await uploadBytes(supabase, packageZipFileName, zipBytes, "application/zip");

    const manifestBytes = new TextEncoder().encode(JSON.stringify(manifest, null, 2));
    await uploadBytes(supabase, manifestFileName, manifestBytes, "application/json");

    const isFirstReadyPack = trackData.distribution_status !== "completed";

    const trackUpdate: Record<string, unknown> = {
      gold_pack_url: manifestPublicUrl,
      certificate_url: certificateHtmlUrl,
      isrc_code: isrcCode,
    };

    if (finalizeTrack && isFirstReadyPack) {
      trackUpdate.distribution_status = "completed";
      trackUpdate.processing_stage = "completed";
      trackUpdate.processing_progress = 100;
      trackUpdate.processing_completed_at = registeredAt || new Date().toISOString();
    }

    await supabase
      .from("tracks")
      .update(trackUpdate)
      .eq("id", trackId);

    const { data: userData } = await supabase
      .from("tracks")
      .select("user_id")
      .eq("id", trackId)
      .single();

    if (userData) {
      await supabase.from("distribution_logs").insert({
        track_id: trackId,
        user_id: userData.user_id,
        action: isFirstReadyPack ? "gold_pack_generated" : "gold_pack_regenerated",
        stage: "level_pro",
        details: {
          manifest_url: manifestPublicUrl,
          zip_url: zipPublicUrl,
          xml_url: xmlPublicUrl,
          certificate_url: certificateHtmlUrl,
          certificate_pdf_url: certificatePdfUrl,
          proof_url: proofBytes ? proofPublicUrl : null,
          promo_video_url: promoVideoBytes ? promoVideoUrl : null,
          has_master: true,
          has_cover: true,
          has_video: Boolean(promoVideoBytes),
        },
      });

      if (isFirstReadyPack) {
        await supabase.from("notifications").insert({
          user_id: userData.user_id,
          type: "system",
          title: "📦 Золотой пакет SILK готов!",
          message: `Ваш трек "${track.title}" готов к дистрибуции. ZIP-пакет, XML, PDF-сертификат и мастер доступны для скачивания.`,
          target_type: "track",
          target_id: trackId,
        });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        goldPack: {
          manifestUrl: manifestPublicUrl,
          zipUrl: zipPublicUrl,
          xmlUrl: xmlPublicUrl,
          certificateUrl: certificateHtmlUrl,
          certificatePdfUrl,
          masterAudioUrl: track.master_audio_url,
          coverUrl: track.cover_url,
          promoVideoUrl: promoVideoBytes ? promoVideoUrl : null,
          proofUrl: proofBytes ? proofPublicUrl : null,
          releaseReady: true,
          missingRequiredAssets,
        },
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("[generate-gold-pack] Error:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
