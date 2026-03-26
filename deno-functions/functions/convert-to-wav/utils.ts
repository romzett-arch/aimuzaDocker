import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

function toReachableAudioUrl(url: string, ffmpegApiUrl?: string): string {
  if (!ffmpegApiUrl) return url;

  try {
    const target = new URL(url);
    if (target.pathname.startsWith("/api/ffmpeg/")) {
      const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "").replace(/\/$/, "");
      return `${baseUrl}${target.pathname.replace(/^\/api\/ffmpeg/, "")}${target.search}`;
    }
  } catch {
    return url;
  }

  return url;
}

async function isUsableAudioUrl(url: string, ffmpegApiUrl?: string): Promise<boolean> {
  try {
    const response = await fetch(toReachableAudioUrl(url, ffmpegApiUrl), { method: "HEAD" });
    if (!response.ok) {
      console.warn(`[convert-wav] HEAD check failed for ${url}: ${response.status}`);
      return false;
    }

    const contentType = response.headers.get("content-type")?.toLowerCase() || "";
    if (contentType.includes("text/html") || contentType.includes("application/json")) {
      console.warn(`[convert-wav] Unexpected content-type for ${url}: ${contentType}`);
      return false;
    }

    const contentLength = Number(response.headers.get("content-length") || "0");
    if (contentLength > 0 && contentLength < 1000) {
      console.warn(`[convert-wav] Suspiciously small file for ${url}: ${contentLength} bytes`);
      return false;
    }

    return true;
  } catch (error) {
    console.warn(`[convert-wav] HEAD check error for ${url}:`, error);
    return false;
  }
}

export async function processWavViaFfmpeg(
  rawWavUrl: string,
  trackTitle: string,
  artistName: string,
  publisherName: string,
  cabinetId: string,
  ffmpegApiUrl: string,
  ffmpegApiSecret: string,
  ffmpegPublicUrl?: string,
): Promise<string | null> {
  try {
    const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "");
    console.log(`[convert-wav] Processing WAV via ffmpeg-api: ${baseUrl}/process-wav`);

    const resp = await fetch(`${baseUrl}/process-wav`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ffmpegApiSecret,
      },
      body: JSON.stringify({
        audio_url: rawWavUrl,
        target_lufs: -14,
        metadata: {
          title: trackTitle || "",
          artist: artistName || "AIMuza Artist",
          album: "AIMuza WAV Export",
          publisher: publisherName || "AIMuza",
          copyright: `© ${new Date().getFullYear()} ${artistName || "AIMuza Artist"} via ${publisherName || "AIMuza"}`,
          comment: `Generated with AIMuza - aimuza.ru | Cabinet ID: ${cabinetId}`,
          TXXX_AIMUZA_CABINET_ID: cabinetId || "",
          TXXX_AIMUZA_PUBLISHER: publisherName || "AIMuza",
        },
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error(`[convert-wav] ffmpeg-api error ${resp.status}: ${errText}`);
      return null;
    }

    const result = await resp.json();
    let outputUrl = result.output_url;
    console.log(`[convert-wav] ffmpeg-api processed OK: ${outputUrl}, LUFS ${result.original_lufs} → ${result.normalized_lufs}`);

    if (outputUrl && outputUrl.includes("/output/")) {
      const filename = outputUrl.split("/output/").pop();
      if (filename) {
        const publicBase = ffmpegPublicUrl || baseUrl;
        outputUrl = `${publicBase}/output/${filename}`;
        console.log(`[convert-wav] Public URL: ${outputUrl}`);
      }
    }

    if (!outputUrl) {
      console.warn("[convert-wav] ffmpeg returned empty output_url");
      return null;
    }

    const isReachable = await isUsableAudioUrl(outputUrl, ffmpegApiUrl);
    if (!isReachable) {
      console.warn(`[convert-wav] ffmpeg output URL is not downloadable: ${outputUrl}`);
      return null;
    }

    return outputUrl;
  } catch (err) {
    console.error(`[convert-wav] ffmpeg processing error:`, err);
    return null;
  }
}

export async function copyWavToStorage(
  supabaseAdmin: SupabaseClient,
  externalUrl: string,
  trackId: string
): Promise<string | null> {
  try {
    console.log(`[convert-wav] Downloading WAV from: ${externalUrl}`);
    const response = await fetch(externalUrl);
    if (!response.ok) {
      console.error(`[convert-wav] Download failed: ${response.status}`);
      return null;
    }
    const blob = await response.blob();
    const arrayBuffer = await blob.arrayBuffer();
    const uint8Array = new Uint8Array(arrayBuffer);
    if (uint8Array.length < 1000) {
      console.error(`[convert-wav] File too small (${uint8Array.length} bytes)`);
      return null;
    }
    console.log(`[convert-wav] Downloaded ${uint8Array.length} bytes`);
    const filePath = `wav/${trackId}.wav`;
    const { error } = await supabaseAdmin.storage
      .from("tracks")
      .upload(filePath, uint8Array, { contentType: "audio/wav", upsert: true });
    if (error) {
      console.error(`[convert-wav] Upload error:`, error);
      return null;
    }
    const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    const publicUrl = `${BASE_URL}/storage/v1/object/public/tracks/${filePath}`;
    console.log(`[convert-wav] Uploaded to: ${publicUrl}`);
    return publicUrl;
  } catch (err) {
    console.error(`[convert-wav] Error:`, err);
    return null;
  }
}
