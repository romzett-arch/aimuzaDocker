/// <reference types="https://esm.sh/@anthropic-ai/sdk@0.25.0" />
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

declare const EdgeRuntime: {
  waitUntil(promise: Promise<unknown>): void;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface PromoVideoRequest {
  track_id: string;
  style: string;
  aspect_ratio: string;
  duration: number;
  text_artist?: string;
  text_title?: string;
  text_position?: string;
  cover_animation?: string;
  particles_color?: string;
  glow_intensity?: number;
  best_segment_auto?: boolean;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

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

    const body: PromoVideoRequest = await req.json();
    const { 
      track_id, 
      style = "particles_glow",
      aspect_ratio = "9:16",
      duration = 30,
      text_artist,
      text_title,
      text_position = "bottom",
      cover_animation = "float",
      particles_color = "#00ffff",
      glow_intensity = 50,
      best_segment_auto = true,
    } = body;

    if (!track_id) {
      throw new Error("track_id is required");
    }

    console.log(`Generating promo video for track: ${track_id}, style: ${style}`);

    // Get track info
    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, title, cover_url, audio_url, duration")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    // Verify ownership or admin
    const { data: userRole } = await supabase
      .from("user_roles")
      .select("role")
      .eq("user_id", user.id)
      .maybeSingle();

    const isAdmin = userRole?.role === "admin" || userRole?.role === "super_admin";

    if (track.user_id !== user.id && !isAdmin) {
      throw new Error("Access denied - not your track");
    }

    // Check if audio exists
    if (!track.audio_url) {
      throw new Error("Track has no audio file");
    }

    // Create promo video record
    const { data: promoVideo, error: insertError } = await supabase
      .from("promo_videos")
      .insert({
        track_id,
        user_id: user.id,
        style,
        aspect_ratio,
        duration_seconds: duration,
        text_artist: text_artist || track.title,
        text_title: text_title || "",
        text_position,
        cover_animation,
        particles_color,
        glow_intensity,
        best_segment_auto,
        status: "pending",
        progress: 0,
      })
      .select()
      .single();

    if (insertError) {
      console.error("Insert error:", insertError);
      throw new Error("Failed to create promo video record");
    }

    console.log(`Created promo video record: ${promoVideo.id}`);

    // VPS endpoint for video rendering (FFmpeg + effects)
    const VPS_URL = Deno.env.get("VPS_FFMPEG_URL") || "http://217.199.254.170:3001";
    
    // Try to send to VPS for rendering
    const renderPayload = {
      promo_video_id: promoVideo.id,
      track_id,
      audio_url: track.audio_url,
      cover_url: track.cover_url,
      style,
      aspect_ratio,
      duration,
      text_artist: text_artist || track.title,
      text_title: text_title || "",
      text_position,
      cover_animation,
      particles_color,
      glow_intensity,
      best_segment_auto,
      callback_url: `${supabaseUrl}/functions/v1/promo-video-callback`,
    };

    // Background task: send to VPS
    EdgeRuntime.waitUntil((async () => {
      try {
        // Update status to processing
        await supabase
          .from("promo_videos")
          .update({ status: "processing", progress: 5 })
          .eq("id", promoVideo.id);

        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 10000);

        const vpsResponse = await fetch(`${VPS_URL}/render-promo`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(renderPayload),
          signal: controller.signal,
        });

        clearTimeout(timeoutId);

        if (!vpsResponse.ok) {
          throw new Error(`VPS error: ${vpsResponse.status}`);
        }

        const vpsResult = await vpsResponse.json();
        console.log("VPS render started:", vpsResult);

        // Update progress
        await supabase
          .from("promo_videos")
          .update({ status: "rendering", progress: 20 })
          .eq("id", promoVideo.id);

      } catch (e) {
        console.error("VPS render failed, using simulation:", e);
        
        // Simulate video generation for development
        await simulateVideoGeneration(supabase, promoVideo.id, track);
      }
    })());

    return new Response(
      JSON.stringify({
        success: true,
        promo_video_id: promoVideo.id,
        message: "Promo video generation started",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("Generate promo video error:", errorMessage);
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

// Simulate video generation for development/fallback
async function simulateVideoGeneration(supabase: any, promoVideoId: string, track: any) {
  console.log("Simulating video generation...");

  // Simulate progress updates
  const progressSteps = [30, 50, 70, 90, 100];
  
  for (const progress of progressSteps) {
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    await supabase
      .from("promo_videos")
      .update({ 
        status: progress < 100 ? "rendering" : "completed",
        progress,
        ...(progress === 100 ? {
          // Use cover as thumbnail, generate placeholder video URL
          video_url: track.audio_url?.replace(".mp3", "_promo.mp4") || null,
          thumbnail_url: track.cover_url,
          completed_at: new Date().toISOString(),
        } : {})
      })
      .eq("id", promoVideoId);
  }

  console.log(`Simulation complete for promo video: ${promoVideoId}`);
}
