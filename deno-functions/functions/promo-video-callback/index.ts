import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

interface CallbackData {
  promo_video_id: string;
  status: "completed" | "failed";
  video_url?: string;
  thumbnail_url?: string;
  file_size_bytes?: number;
  error_message?: string;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const body: CallbackData = await req.json();
    const { promo_video_id, status, video_url, thumbnail_url, file_size_bytes, error_message } = body;

    if (!promo_video_id) {
      throw new Error("promo_video_id is required");
    }

    console.log(`Promo video callback: ${promo_video_id}, status: ${status}`);

    // Get promo video record
    const { data: promoVideo, error: fetchError } = await supabase
      .from("promo_videos")
      .select("id, track_id, user_id")
      .eq("id", promo_video_id)
      .single();

    if (fetchError || !promoVideo) {
      throw new Error("Promo video not found");
    }

    // Update status
    const updateData: Record<string, unknown> = {
      status,
      progress: status === "completed" ? 100 : undefined,
      updated_at: new Date().toISOString(),
    };

    if (status === "completed") {
      updateData.video_url = video_url;
      updateData.thumbnail_url = thumbnail_url;
      updateData.file_size_bytes = file_size_bytes;
      updateData.completed_at = new Date().toISOString();

      // Send notification to user
      await supabase.from("notifications").insert({
        user_id: promoVideo.user_id,
        type: "system",
        title: "🎬 Промо-видео готово!",
        message: "Ваше промо-видео успешно создано и готово к скачиванию",
        target_type: "promo_video",
        target_id: promo_video_id,
      });
    } else if (status === "failed") {
      updateData.error_message = error_message || "Unknown error";

      // Notify user about failure
      await supabase.from("notifications").insert({
        user_id: promoVideo.user_id,
        type: "system",
        title: "Ошибка генерации видео",
        message: error_message || "Не удалось создать промо-видео. Попробуйте ещё раз.",
        target_type: "promo_video",
        target_id: promo_video_id,
      });
    }

    const { error: updateError } = await supabase
      .from("promo_videos")
      .update(updateData)
      .eq("id", promo_video_id);

    if (updateError) {
      console.error("Update error:", updateError);
      throw new Error("Failed to update promo video");
    }

    console.log(`Promo video ${promo_video_id} updated to ${status}`);

    return new Response(
      JSON.stringify({ success: true }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("Promo video callback error:", errorMessage);
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
