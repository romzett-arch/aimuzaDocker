import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface NormalizeResult {
  success: boolean;
  normalized_url?: string;
  original_lufs: number;
  normalized_lufs: number;
  peak_before: number;
  peak_after: number;
  metadata_stripped: boolean;
  metadata_branded: boolean;
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
    const { 
      audio_url, 
      track_id, 
      target_lufs = -14, 
      strip_metadata = true,
      brand_metadata = true 
    } = body;

    if (!audio_url || !track_id) {
      throw new Error("audio_url and track_id are required");
    }

    // Get track and user info for branding
    const { data: track } = await supabase
      .from("tracks")
      .select("title, user_id, audio_url, master_audio_url, normalized_audio_url, profiles!tracks_user_id_fkey(username)")
      .eq("id", track_id)
      .single();

    if (!track) {
      throw new Error("Track not found");
    }

    if (track.user_id !== user.id) {
      throw new Error("Forbidden");
    }

    const trustedAudioUrl = resolveTrustedTrackUrl(
      audio_url,
      [track.audio_url, track.master_audio_url, track.normalized_audio_url],
      req.url,
    );

    if (!trustedAudioUrl) {
      throw new Error("audio_url must match the track file URL");
    }

    const username = (track as any)?.profiles?.username || "Unknown";

    console.log(`Normalizing audio for track ${track_id}: ${trustedAudioUrl}`);

    const normalizePayload = {
      audio_url: trustedAudioUrl,
      target_lufs,
      strip_metadata,
      brand_metadata,
      metadata: brand_metadata ? {
        artist: username,
        title: track?.title || "Untitled",
        album: "AImuza",
        comment: `Generated on aimuza.ru | User: ${username}`,
        date: new Date().getFullYear().toString(),
        encoder: "AImuza Music Terminal",
        copyright: `© ${new Date().getFullYear()} ${username} via AImuza`,
        user_id: user.id,
        website: "https://aimuza.ru",
      } : undefined,
    };

    let result: NormalizeResult;

    // Try FFmpeg API with auth
  const vpsNormalize = async (): Promise<NormalizeResult | null> => {
      if (!ffmpegApiUrl || !ffmpegApiSecret) {
        console.log("FFmpeg API not configured");
        return null;
      }
      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 120000); // 2 min for two-pass loudnorm
        
        const baseUrl = ffmpegApiUrl!.replace(/\/(clean-metadata|analyze|normalize)\/?$/, "");
        const bodyStr = JSON.stringify(normalizePayload);
        console.log("Sending normalize request, body length:", bodyStr.length);
        
        const resp = await fetch(`${baseUrl}/normalize`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            "x-api-key": ffmpegApiSecret,
          },
          body: bodyStr,
          signal: controller.signal,
        });
        
        clearTimeout(timeoutId);
        if (!resp.ok) {
          const errText = await resp.text();
          console.log("FFmpeg API normalize error:", resp.status, errText);
          return null;
        }
        
        const vpsResult = await resp.json();
        console.log("FFmpeg API normalize result:", JSON.stringify(vpsResult));
        if (vpsResult.output_url || vpsResult.normalized_url) {
          return {
            success: true,
            normalized_url: vpsResult.output_url || vpsResult.normalized_url,
            original_lufs: vpsResult.original_lufs ?? -18,
            normalized_lufs: vpsResult.normalized_lufs ?? target_lufs,
            peak_before: vpsResult.peak_before ?? -1,
            peak_after: vpsResult.peak_after ?? -1,
            metadata_stripped: strip_metadata,
            metadata_branded: brand_metadata,
          };
        }
        return null;
      } catch (e) {
        console.log("FFmpeg API normalize failed:", e);
        return null;
      }
    };

    const vpsResult = await vpsNormalize();
    if (vpsResult) {
      result = vpsResult;
      console.log("Using FFmpeg API normalization result");
    } else {
      throw new Error("FFmpeg API unavailable");
    }

    // Update track_health_reports with normalization results
    if (result.success) {
      const { error: healthError } = await supabase
        .from("track_health_reports")
        .upsert({
          track_id,
          lufs_normalized: result.normalized_lufs,
          normalized_audio_url: result.normalized_url,
          normalization_status: "completed",
          updated_at: new Date().toISOString(),
        }, {
          onConflict: "track_id",
          ignoreDuplicates: false,
        });

      if (healthError) {
        console.error("Error updating health report:", healthError);
      }

      // Also update legacy fields on tracks table
      await supabase
        .from("tracks")
        .update({
          audio_normalized: true,
          audio_lufs: result.normalized_lufs,
          audio_peak_db: result.peak_after,
          normalized_audio_url: result.normalized_url,
          metadata_cleaned: strip_metadata,
          metadata_branded: brand_metadata,
        })
        .eq("id", track_id);
    }

    return new Response(
      JSON.stringify(result),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("Normalize error:", errorMessage);
    const status = errorMessage === "FFmpeg API unavailable" ? 503 : 400;
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
