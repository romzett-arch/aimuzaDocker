import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface DistributionRequest {
  track_id: string;
  platforms?: string[];
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Verify admin role
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Authorization required");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      throw new Error("Invalid token");
    }

    // Check admin role
    const { data: roleData } = await supabase
      .from("user_roles")
      .select("role")
      .eq("user_id", user.id)
      .single();

    if (!roleData || !["admin", "super_admin"].includes(roleData.role)) {
      throw new Error("Admin access required");
    }

    const body: DistributionRequest = await req.json();
    const { track_id, platforms = ["yandex_music", "vk_music", "spotify", "apple_music"] } = body;

    // Get track data
    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select(`
        id, title, description, audio_url, cover_url, duration,
        performer_name, music_author, lyrics_author, lyrics,
        isrc_code, label_name,
        profile:profiles!tracks_user_id_fkey(username, user_id)
      `)
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    // Validate required fields
    if (!track.audio_url) throw new Error("Audio URL is required");
    if (!track.cover_url) throw new Error("Cover URL is required");
    if (!track.performer_name) throw new Error("Performer name is required");

    // Generate ISRC if not exists
    let isrcCode = track.isrc_code;
    if (!isrcCode) {
      // Format: RU-NFA-YY-NNNNN (Нотафея label code)
      const year = new Date().getFullYear().toString().slice(-2);
      const randomNum = Math.floor(Math.random() * 99999).toString().padStart(5, "0");
      isrcCode = `RUNFA${year}${randomNum}`;

      await supabase
        .from("tracks")
        .update({ isrc_code: isrcCode })
        .eq("id", track_id);
    }

    // ============================================
    // PLACEHOLDER: Здесь будет интеграция с дистрибьютором
    // Например: Believe, DistroKid API, или российский дистрибьютор
    // ============================================
    
    // Формируем данные для дистрибьютора
    const distributionPayload = {
      isrc: isrcCode,
      title: track.title,
      artist: track.performer_name,
      composer: track.music_author || track.performer_name,
      lyricist: track.lyrics_author,
      label: track.label_name || "Нота-Фея",
      genre: "Electronic", // TODO: Get from track
      audio_url: track.audio_url,
      cover_url: track.cover_url,
      duration_seconds: track.duration,
      lyrics: track.lyrics,
      release_date: new Date().toISOString().split("T")[0],
      platforms: platforms,
    };

    console.log("Distribution payload prepared:", JSON.stringify(distributionPayload, null, 2));

    // TODO: Отправка в API дистрибьютора
    // const distributorResponse = await fetch("https://api.distributor.ru/submit", {
    //   method: "POST",
    //   headers: { "Authorization": `Bearer ${Deno.env.get("DISTRIBUTOR_API_KEY")}` },
    //   body: JSON.stringify(distributionPayload),
    // });

    // Update track status
    await supabase
      .from("tracks")
      .update({
        distribution_status: "submitted",
        distribution_platforms: platforms,
        distribution_submitted_at: new Date().toISOString(),
      })
      .eq("id", track_id);

    // Log the action
    console.log(`Track ${track_id} submitted for distribution to: ${platforms.join(", ")}`);

    return new Response(
      JSON.stringify({
        success: true,
        message: "Track submitted for distribution",
        isrc_code: isrcCode,
        platforms: platforms,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("Distribution error:", errorMessage);
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
