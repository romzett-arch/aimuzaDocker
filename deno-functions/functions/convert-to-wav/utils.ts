import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export async function processWavViaFfmpeg(
  rawWavUrl: string,
  trackTitle: string,
  artistName: string,
  ffmpegApiUrl: string,
  ffmpegApiSecret: string,
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
          copyright: `© ${new Date().getFullYear()} ${artistName || "AIMuza Artist"} via AIMuza`,
          comment: "Generated with AIMuza - aimuza.ru",
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
        outputUrl = `${baseUrl}/output/${filename}`;
        console.log(`[convert-wav] Rewrote to internal URL: ${outputUrl}`);
      }
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
