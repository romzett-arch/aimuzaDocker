import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./constants.ts";
import { refundUser } from "./refund.ts";

interface HandleVideoExistsParams {
  taskId: string;
  trackId: string;
  addonServiceId: string;
  price: number;
  sunoApiKey: string;
  supabase: SupabaseClient;
  userId: string | null;
  isInternalCall: boolean;
}

export async function handleVideoAlreadyExists(
  params: HandleVideoExistsParams,
): Promise<Response | null> {
  const { taskId, trackId, addonServiceId, price, sunoApiKey, supabase, userId, isInternalCall } = params;

  const statusResponse = await fetch(`https://api.sunoapi.org/api/v1/mp4/query?taskId=${taskId}`, {
    method: "GET",
    headers: {
      "Authorization": `Bearer ${sunoApiKey}`,
      "Content-Type": "application/json",
    },
  });

  const statusText = await statusResponse.text();
  console.log("Suno video status response:", statusResponse.status, statusText);

  let statusData;
  try {
    statusData = JSON.parse(statusText);
  } catch {
    if (!isInternalCall && userId) {
      await refundUser(supabase, userId, price);
    }
    throw new Error("Video already exists but failed to fetch URL");
  }

  if (statusData.code === 200 && statusData.data) {
    const videoUrl = statusData.data.video_url || statusData.data.mp4_url || statusData.data.url;

    if (videoUrl) {
      console.log(`Found existing video: ${videoUrl}`);

      if (!isInternalCall && userId) {
        await refundUser(supabase, userId, price);
      }

      await supabase
        .from("track_addons")
        .update({
          status: "completed",
          result_url: videoUrl,
          updated_at: new Date().toISOString()
        })
        .eq("track_id", trackId)
        .eq("addon_service_id", addonServiceId);

      return new Response(
        JSON.stringify({
          success: true,
          video_url: videoUrl,
          message: "Video already exists",
          already_exists: true,
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }
  }

  if (!isInternalCall && userId) {
    await refundUser(supabase, userId, price);
  }
  throw new Error("Video exists but could not retrieve URL");
}
