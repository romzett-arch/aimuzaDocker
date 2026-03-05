/**
 * Получить длительность аудио из FFmpeg API.
 * Используется когда erweima.ai возвращает duration: null.
 */
export async function getDurationFromFfmpeg(audioUrl: string): Promise<number | null> {
  const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
  const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "http://api:3000";

  if (!ffmpegApiUrl || !ffmpegApiSecret) {
    console.log("[ffmpeg-duration] FFmpeg API not configured");
    return null;
  }

  // FFmpeg контейнер не может достучаться до localhost — используем внутренний URL
  let urlForFfmpeg = audioUrl;
  if (audioUrl.includes("localhost") || audioUrl.includes("127.0.0.1")) {
    try {
      const m = audioUrl.match(/\/storage\/v1\/object\/public\/(.+)$/);
      if (m) {
        urlForFfmpeg = `${supabaseUrl}/storage/v1/object/public/${m[1]}`;
        console.log(`[ffmpeg-duration] Using internal URL for FFmpeg: ${urlForFfmpeg}`);
      }
    } catch {
      // ignore
    }
  }

  try {
    const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "");
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 15000);

    const resp = await fetch(`${baseUrl}/analyze`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ffmpegApiSecret,
      },
      body: JSON.stringify({ audio_url: urlForFfmpeg }),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!resp.ok) {
      console.log(`[ffmpeg-duration] FFmpeg analyze failed: ${resp.status}`);
      return null;
    }

    const data = await resp.json();
    const dur = data?.format?.duration != null ? parseFloat(data.format.duration) : null;
    if (dur != null && dur > 0) {
      console.log(`[ffmpeg-duration] Got duration: ${Math.round(dur)}s`);
      return Math.round(dur);
    }
    return null;
  } catch (err) {
    console.error("[ffmpeg-duration] Error:", err instanceof Error ? err.message : err);
    return null;
  }
}
