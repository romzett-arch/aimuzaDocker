import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface AnalysisResult {
  spectrum_ok: boolean;
  high_freq_cutoff: number;
  upscale_detected: boolean;
  quality_score: number;
  original_lufs: number;
  peak_db: number;
  dynamic_range: number;
  needs_normalization: boolean;
  sample_rate: number;
  bit_depth: number;
  channels: number;
  duration: number;
  format: string;
  master_quality: boolean;
  recommendations: string[];
}

function normalizeTrackUrl(rawUrl: string | null | undefined, requestUrl: string): string | null {
  if (!rawUrl) return null;

  try {
    const baseUrl = Deno.env.get("BASE_URL") || new URL(requestUrl).origin;
    const normalized = new URL(rawUrl, baseUrl);
    if (!["http:", "https:"].includes(normalized.protocol)) {
      return null;
    }
    normalized.hash = "";
    return normalized.toString();
  } catch {
    return null;
  }
}

function resolveTrustedTrackUrl(
  candidateUrl: string,
  allowedUrls: Array<string | null | undefined>,
  requestUrl: string,
): string | null {
  const normalizedCandidate = normalizeTrackUrl(candidateUrl, requestUrl);
  if (!normalizedCandidate) return null;

  const trustedUrls = new Set(
    allowedUrls
      .map((value) => normalizeTrackUrl(value, requestUrl))
      .filter((value): value is string => Boolean(value)),
  );

  return trustedUrls.has(normalizedCandidate) ? normalizedCandidate : null;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
    const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");

    // Verify user authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Authorization required");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      throw new Error("Invalid token");
    }

    const body = await req.json();
    const { audio_url, track_id } = body;

    if (!audio_url) {
      throw new Error("audio_url is required");
    }

    let trustedAudioUrl = normalizeTrackUrl(audio_url, req.url);

    if (track_id) {
      const { data: track, error: trackError } = await supabase
        .from("tracks")
        .select("id, user_id, audio_url, master_audio_url, normalized_audio_url")
        .eq("id", track_id)
        .maybeSingle();

      if (trackError || !track) {
        throw new Error("Track not found");
      }

      if (track.user_id !== user.id) {
        throw new Error("Forbidden");
      }

      trustedAudioUrl = resolveTrustedTrackUrl(
        audio_url,
        [track.audio_url, track.master_audio_url, track.normalized_audio_url],
        req.url,
      );

      if (!trustedAudioUrl) {
        throw new Error("audio_url must match the track file URL");
      }
    }

    if (!trustedAudioUrl) {
      throw new Error("Invalid audio_url");
    }

    console.log(`Analyzing audio: ${trustedAudioUrl}`);

    let analysisResult: AnalysisResult;

    // Try FFmpeg API with auth
    const vpsAnalysis = async (): Promise<AnalysisResult | null> => {
      if (!ffmpegApiUrl || !ffmpegApiSecret) {
        console.log("FFmpeg API not configured");
        return null;
      }
      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 10000);

        const baseUrl = ffmpegApiUrl!.replace(/\/(clean-metadata|analyze|normalize)\/?$/, "");
        const probeResponse = await fetch(`${baseUrl}/analyze`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-api-key": ffmpegApiSecret,
          },
          body: JSON.stringify({ audio_url: trustedAudioUrl }),
          signal: controller.signal,
        });

        clearTimeout(timeoutId);

        if (!probeResponse.ok) {
          console.log("FFmpeg API analyze error:", probeResponse.status);
          return null;
        }

        const vpsResult = await probeResponse.json();
        return parseVpsResult(vpsResult);
      } catch (e) {
        console.log("FFmpeg API call failed:", e);
        return null;
      }
    };

    const vpsResult = await vpsAnalysis();
    if (vpsResult) {
      analysisResult = vpsResult;
      console.log("Using FFmpeg API analysis result");
    } else {
      throw new Error("FFmpeg API unavailable");
    }

    // Save analysis to track_health_reports table if track_id provided
    if (track_id) {
      const { error: healthError } = await supabase
        .from("track_health_reports")
        .upsert({
          track_id,
          quality_score: analysisResult.quality_score,
          lufs_original: analysisResult.original_lufs,
          peak_db: analysisResult.peak_db,
          dynamic_range: analysisResult.dynamic_range,
          spectrum_ok: analysisResult.spectrum_ok,
          high_freq_cutoff: analysisResult.high_freq_cutoff,
          upscale_detected: analysisResult.upscale_detected,
          sample_rate: analysisResult.sample_rate,
          bit_depth: analysisResult.bit_depth,
          channels: analysisResult.channels,
          duration: analysisResult.duration,
          format: analysisResult.format,
          master_quality: analysisResult.master_quality,
          recommendations: analysisResult.recommendations,
          analysis_status: "completed",
          updated_at: new Date().toISOString(),
        }, {
          onConflict: "track_id",
        });

      if (healthError) {
        console.error("Error saving health report:", healthError);
      } else {
        console.log("Health report saved for track:", track_id);
      }

      // Also update legacy fields on tracks table (включая duration — исправляет 180 fallback)
      await supabase
        .from("tracks")
        .update({
          audio_quality_score: analysisResult.quality_score,
          audio_sample_rate: analysisResult.sample_rate,
          audio_bit_depth: analysisResult.bit_depth,
          audio_lufs: analysisResult.original_lufs,
          audio_peak_db: analysisResult.peak_db,
          upscale_detected: analysisResult.upscale_detected,
          needs_master_wav: !analysisResult.master_quality,
          ...(analysisResult.duration > 0 && { duration: Math.round(analysisResult.duration) }),
        })
        .eq("id", track_id);
    }

    return new Response(
      JSON.stringify({ success: true, analysis: analysisResult }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("Analysis error:", errorMessage);
    const status = errorMessage === "FFmpeg API unavailable" ? 503 : 400;
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

function parseVpsResult(vpsResult: any): AnalysisResult {
  const { format, streams, lufs, spectrum } = vpsResult;
  const audioStream = streams?.find((s: any) => s.codec_type === "audio") || {};

  const highFreqCutoff = spectrum?.high_freq_cutoff || 20000;
  const upscaleDetected = highFreqCutoff < 16000;

  let qualityScore = 10;
  if (upscaleDetected) qualityScore -= 3;
  if (audioStream.sample_rate < 44100) qualityScore -= 2;
  if (audioStream.bits_per_sample < 16) qualityScore -= 2;
  if (lufs?.integrated > -8) qualityScore -= 1;
  qualityScore = Math.max(1, Math.min(10, qualityScore));

  const sampleRate = parseInt(audioStream.sample_rate) || 44100;
  const bitDepth = audioStream.bits_per_sample || (audioStream.codec_name === "flac" ? 24 : 16);
  const originalLufs = lufs?.integrated || -16;

  const recommendations: string[] = [];
  if (upscaleDetected) {
    recommendations.push("Обнаружен апскейл. Рекомендуется загрузить оригинальный файл высокого качества.");
  }
  if (originalLufs > -12 || originalLufs < -18) {
    recommendations.push("Громкость будет нормализована до -14 LUFS для стриминговых платформ.");
  }
  if (bitDepth < 24 || !["wav", "flac", "aiff"].includes(format?.format_name || "")) {
    recommendations.push("Для дистрибуции рекомендуется WAV 24-bit.");
  }

  return {
    spectrum_ok: !upscaleDetected,
    high_freq_cutoff: highFreqCutoff,
    upscale_detected: upscaleDetected,
    quality_score: qualityScore,
    original_lufs: originalLufs,
    peak_db: lufs?.true_peak || -1,
    dynamic_range: lufs?.range || 8,
    needs_normalization: Math.abs(originalLufs - (-14)) > 1,
    sample_rate: sampleRate,
    bit_depth: bitDepth,
    channels: audioStream.channels || 2,
    duration: parseFloat(format?.duration) || 0,
    format: format?.format_name || "unknown",
    master_quality: bitDepth >= 24 && ["wav", "flac", "aiff"].includes(format?.format_name || ""),
    recommendations,
  };
}

