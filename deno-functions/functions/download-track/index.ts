import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
  const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");

  try {
    // Validate auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });
    
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const userId = user.id;

    const body = await req.json();
    const { track_id, include_blockchain = false, stream = false } = body;

    if (!track_id) {
      return new Response(
        JSON.stringify({ error: "track_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log("Download track request:", { track_id, userId, include_blockchain, stream });

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get track info
    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, title, audio_url, status, created_at")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      return new Response(
        JSON.stringify({ error: "Track not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Check ownership
    if (track.user_id !== userId) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!track.audio_url) {
      return new Response(
        JSON.stringify({ error: "Track has no audio" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get user profile for artist name
    const { data: profile } = await supabase
      .from("profiles")
      .select("username")
      .eq("user_id", userId)
      .single();

    const artistName = profile?.username || "AIMuza Artist";
    const shortUserId = userId.substring(0, 8);
    const createdDate = new Date(track.created_at).toISOString().split("T")[0];
    const safeTitle = track.title.replace(/[^a-zA-Zа-яА-Я0-9\s]/g, "_");
    const filename = `${safeTitle}.mp3`;

    // Prepare extended metadata
    const extendedMetadata = {
      title: track.title,
      artist: artistName,
      album: "AIMuza",
      publisher: "AIMuza",
      comment: `Generated with AIMuza - aimuza.ru | User: ${artistName} (${shortUserId}) | Date: ${createdDate}`,
      copyright: `© ${new Date().getFullYear()} ${artistName} via AIMuza`,
      custom: {
        TXXX_AIMUZA_USER_ID: userId,
        TXXX_AIMUZA_USERNAME: artistName,
        TXXX_AIMUZA_WEBSITE: "aimuza.ru",
        TXXX_AIMUZA_DATE: createdDate,
        TXXX_AIMUZA_TRACK_ID: track_id,
      } as Record<string, string>,
    };

    // If blockchain protection is requested, get deposit info
    let blockchainHash: string | null = null;
    if (include_blockchain) {
      const { data: deposit } = await supabase
        .from("track_deposits")
        .select("metadata_hash, blockchain_tx_id, deposited_at")
        .eq("track_id", track_id)
        .eq("status", "completed")
        .order("deposited_at", { ascending: false })
        .limit(1)
        .single();

      if (deposit?.metadata_hash) {
        blockchainHash = deposit.metadata_hash;
        extendedMetadata.custom["TXXX_BLOCKCHAIN_HASH"] = deposit.metadata_hash;
        if (deposit.blockchain_tx_id) {
          extendedMetadata.custom["TXXX_BLOCKCHAIN_TX"] = deposit.blockchain_tx_id;
        }
        extendedMetadata.custom["TXXX_BLOCKCHAIN_DATE"] = deposit.deposited_at;
        extendedMetadata.comment += ` | Blockchain: ${deposit.metadata_hash.substring(0, 16)}...`;
      }
    }

    // If FFmpeg API is not configured, return/stream original
    if (!ffmpegApiUrl || !ffmpegApiSecret) {
      console.log("FFmpeg API not configured, returning original");
      if (stream) {
        return await proxyFile(track.audio_url, filename, corsHeaders);
      }
      return new Response(
        JSON.stringify({ 
          success: true, 
          download_url: track.audio_url,
          filename,
          cleaned: false,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Call FFmpeg API for metadata cleaning
    console.log("Calling FFmpeg API for metadata cleaning...");
    
    const baseUrl = ffmpegApiUrl!.replace(/\/(clean-metadata|analyze|normalize)\/?$/, "");
    const ffmpegResponse = await fetch(`${baseUrl}/clean-metadata`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ffmpegApiSecret!,
      },
      body: JSON.stringify({
        audio_url: track.audio_url,
        metadata: extendedMetadata,
      }),
    });

    if (!ffmpegResponse.ok) {
      const errorText = await ffmpegResponse.text();
      console.error("FFmpeg API error:", ffmpegResponse.status, errorText);
      
      // Fallback to original
      if (stream) {
        return await proxyFile(track.audio_url, filename, corsHeaders);
      }
      return new Response(
        JSON.stringify({ 
          success: true, 
          download_url: track.audio_url,
          filename,
          cleaned: false,
          warning: "Metadata cleaning unavailable",
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const ffmpegResult = await ffmpegResponse.json();
    console.log("FFmpeg API response:", ffmpegResult);

    const outputUrl = ffmpegResult.output_url || track.audio_url;
    const cleaned = !!ffmpegResult.output_url;

    // Increment download count
    await supabase.rpc("increment_download_count", { track_id });

    // Stream mode: proxy the file through edge function to avoid CORS
    if (stream) {
      console.log("Streaming file to client:", outputUrl);
      return await proxyFile(outputUrl, filename, corsHeaders);
    }

    // JSON mode (legacy)
    return new Response(
      JSON.stringify({ 
        success: true, 
        download_url: outputUrl,
        filename,
        cleaned,
        metadata: {
          artist: artistName,
          user_id: shortUserId,
          date: createdDate,
          blockchain_protected: !!blockchainHash,
        }
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: unknown) {
    console.error("Error in download-track:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

/**
 * Proxy a file URL through the edge function to avoid CORS issues.
 * Returns the file as binary with proper Content-Disposition header.
 */
async function proxyFile(
  url: string, 
  filename: string, 
  corsHeaders: Record<string, string>
): Promise<Response> {
  try {
    // Внутри Docker, localhost не доступен — заменяем на nginx hostname
    let internalUrl = url;
    if (url.includes('localhost')) {
      internalUrl = url.replace('http://localhost', 'http://nginx');
    }
    const fileResponse = await fetch(internalUrl);
    if (!fileResponse.ok) {
      throw new Error(`Failed to fetch file: ${fileResponse.status}`);
    }

    const fileData = await fileResponse.arrayBuffer();
    const encodedFilename = encodeURIComponent(filename);

    return new Response(fileData, {
      headers: {
        ...corsHeaders,
        "Content-Type": "audio/mpeg",
        "Content-Disposition": `attachment; filename="${encodedFilename}"; filename*=UTF-8''${encodedFilename}`,
        "Content-Length": String(fileData.byteLength),
      },
    });
  } catch (err) {
    console.error("Proxy file error:", err);
    return new Response(
      JSON.stringify({ error: "Failed to proxy file" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
}
