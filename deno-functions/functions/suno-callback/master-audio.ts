import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const MASTER_TARGET_LUFS = -10;
const MASTER_TARGET_TRUE_PEAK_DB = -1;
const MP3_ENCODING_LOUDNESS_TARGET_LUFS = -9.5;
const MP3_ENCODING_TRUE_PEAK_TARGET_DB = -1.7;
const MASTER_ATTEMPTS = 3;

function ffmpegBaseUrl(): string {
  const configured = Deno.env.get("FFMPEG_API_URL") || Deno.env.get("VPS_FFMPEG_URL");
  if (!configured) throw new Error("FFMPEG_API_URL is not configured");
  return configured.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "").replace(/\/$/, "");
}

function toInternalStorageUrl(url: string): string {
  const supabaseUrl = (Deno.env.get("SUPABASE_URL") || "").replace(/\/$/, "");
  if (url.startsWith("/") && supabaseUrl) return `${supabaseUrl}${url}`;

  try {
    const parsed = new URL(url);
    if (supabaseUrl && parsed.pathname.startsWith("/storage/v1/object/public/")) {
      return `${supabaseUrl}${parsed.pathname}${parsed.search}`;
    }
  } catch {
    // The FFmpeg service will report a useful validation error.
  }

  return url;
}

function toInternalFfmpegOutput(url: string, baseUrl: string): string {
  try {
    const parsed = new URL(url);
    if (parsed.pathname.includes("/output/")) {
      return `${baseUrl}/output/${parsed.pathname.split("/output/").pop()}${parsed.search}`;
    }
  } catch {
    // Keep the returned URL unchanged if it is already directly reachable.
  }
  return url;
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

export async function createAndStorePlaybackMaster(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  originalAudioUrl: string,
): Promise<{ url: string; lufs: number; peakDb: number }> {
  const baseUrl = ffmpegBaseUrl();
  const apiSecret = Deno.env.get("FFMPEG_API_SECRET") || "";
  let lastError: unknown = null;

  for (let attempt = 1; attempt <= MASTER_ATTEMPTS; attempt++) {
    try {
      const response = await fetch(`${baseUrl}/normalize`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          ...(apiSecret ? { "x-api-key": apiSecret } : {}),
        },
        body: JSON.stringify({
          audio_url: toInternalStorageUrl(originalAudioUrl),
          // MP3 encode/decode measures about 0.5 LU quieter than loudnorm's
          // pre-codec output, so compensate internally for a measured -10 LUFS file.
          target_lufs: MP3_ENCODING_LOUDNESS_TARGET_LUFS,
          // MP3 decoding can add ~0.3 dB inter-sample overshoot. The internal
          // margin keeps the measured final file at or below the public -1 dBTP ceiling.
          target_true_peak: MP3_ENCODING_TRUE_PEAK_TARGET_DB,
          strip_metadata: true,
          brand_metadata: false,
        }),
      });

      const result = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(String(result?.message || `ffmpeg_master_failed_${response.status}`));
      }

      const temporaryUrl = String(result?.output_url || result?.normalized_url || "");
      if (!temporaryUrl) throw new Error("ffmpeg_master_url_missing");

      const masterResponse = await fetch(toInternalFfmpegOutput(temporaryUrl, baseUrl));
      if (!masterResponse.ok) throw new Error(`master_download_failed_${masterResponse.status}`);
      const masterBytes = new Uint8Array(await masterResponse.arrayBuffer());
      if (masterBytes.length < 10_000) throw new Error(`master_file_too_small_${masterBytes.length}`);

      const filePath = `masters/${trackId}.mp3`;
      const { error: uploadError } = await supabaseAdmin.storage.from("tracks").upload(
        filePath,
        masterBytes,
        { contentType: "audio/mpeg", upsert: true },
      );
      if (uploadError) throw uploadError;

      const publicBaseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
      return {
        url: `${publicBaseUrl.replace(/\/$/, "")}/storage/v1/object/public/tracks/${filePath}`,
        lufs: MASTER_TARGET_LUFS,
        peakDb: MASTER_TARGET_TRUE_PEAK_DB,
      };
    } catch (error) {
      lastError = error;
      console.error(`[suno-callback] Master attempt ${attempt}/${MASTER_ATTEMPTS} failed:`, error);
      if (attempt < MASTER_ATTEMPTS) await sleep(750 * 2 ** (attempt - 1));
    }
  }

  throw lastError instanceof Error ? lastError : new Error("master_creation_failed");
}
