import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "http://api:3000";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// Download external image and upload to local storage
async function downloadCoverToStorage(
  externalUrl: string,
  trackId: string,
  index: number
): Promise<string | null> {
  try {
    console.log(`Downloading cover from: ${externalUrl}`);
    const resp = await fetch(externalUrl);
    if (!resp.ok) {
      console.log(`Download failed: ${resp.status}`);
      return null;
    }
    const blob = await resp.blob();
    const buffer = new Uint8Array(await blob.arrayBuffer());

    // Determine extension from content type
    const contentType = blob.type || "image/png";
    const ext = contentType.includes("jpeg") || contentType.includes("jpg") ? "jpg" : "png";
    const filePath = `covers/${trackId}-suno-${index}.${ext}`;

    // Upload to local storage API
    const uploadResp = await fetch(
      `${SUPABASE_URL}/storage/v1/object/tracks/${filePath}`,
      {
        method: "PUT",
        headers: {
          "Content-Type": contentType,
          "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
        },
        body: buffer,
      }
    );

    if (!uploadResp.ok) {
      const errText = await uploadResp.text();
      console.log(`Upload to storage failed: ${uploadResp.status} ${errText}`);
      return null;
    }

    const localUrl = `${BASE_URL}/storage/v1/object/public/tracks/${filePath}`;
    console.log(`Cover saved to storage: ${localUrl}`);
    return localUrl;
  } catch (err) {
    console.error(`Error downloading cover:`, err);
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Verify callback secret
    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    if (callbackSecret) {
      const url = new URL(req.url);
      const headerToken = req.headers.get("x-callback-secret") || req.headers.get("authorization")?.replace("Bearer ", "");
      const queryToken = url.searchParams.get("secret");

      if (headerToken !== callbackSecret && queryToken !== callbackSecret) {
        console.error("Invalid callback secret provided");
        return new Response(
          JSON.stringify({ error: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      console.log("Cover callback secret verified");
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const callbackData = await req.json();
    console.log("Suno cover callback received:", JSON.stringify(callbackData));

    const code = callbackData?.code;
    const msg = callbackData?.msg;
    const coverTaskId = callbackData?.data?.taskId;
    const images = callbackData?.data?.images || [];

    console.log(`Cover callback: code=${code}, taskId=${coverTaskId}, images=${images.length}`);

    // Handle errors
    if (code !== 200) {
      console.error(`Cover generation failed: code=${code}, msg=${msg}`);
      // Remove cover_task_id marker from tracks (so it's clear it failed)
      if (coverTaskId) {
        const { data: failedTracks } = await supabaseAdmin
          .from("tracks")
          .select("id, description")
          .ilike("description", `%[cover_task_id: ${coverTaskId}]%`);

        for (const track of failedTracks || []) {
          const cleanDesc = (track.description || "")
            .replace(`\n\n[cover_task_id: ${coverTaskId}]`, "")
            .replace(`[cover_task_id: ${coverTaskId}]`, "")
            .trim();
          await supabaseAdmin
            .from("tracks")
            .update({ description: cleanDesc || null })
            .eq("id", track.id);
        }
      }
      return new Response(
        JSON.stringify({ received: true, message: "Cover generation failed" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (images.length === 0) {
      console.log("No cover images in callback");
      return new Response(
        JSON.stringify({ received: true, message: "No images" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Find tracks matching this cover_task_id
    let matchedTracks: Array<{ id: string; title: string | null; description: string | null; cover_url: string | null }> = [];

    if (coverTaskId) {
      const { data: tracks, error } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description, cover_url")
        .ilike("description", `%[cover_task_id: ${coverTaskId}]%`)
        .order("created_at", { ascending: true });

      if (error) {
        console.error("Error finding tracks by cover_task_id:", error);
      } else if (tracks && tracks.length > 0) {
        matchedTracks = tracks;
        console.log(`Found ${tracks.length} tracks for cover_task_id ${coverTaskId}`);
      }
    }

    if (matchedTracks.length === 0) {
      console.warn(`No tracks found for cover_task_id ${coverTaskId}`);
      return new Response(
        JSON.stringify({ received: true, warning: "No matching tracks" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Assign images to tracks: image[0] → track[0], image[1] → track[1]
    // Suno usually generates 2 cover variants
    let updatedCount = 0;

    for (let i = 0; i < matchedTracks.length; i++) {
      const track = matchedTracks[i];
      const imageUrl = images[i] || images[0]; // fallback to first image if fewer images than tracks

      if (!imageUrl) continue;

      // Download cover to local storage
      const localCoverUrl = await downloadCoverToStorage(imageUrl, track.id, i);
      const finalCoverUrl = localCoverUrl || imageUrl;

      // Clean description: remove cover_task_id marker
      const cleanDesc = (track.description || "")
        .replace(`\n\n[cover_task_id: ${coverTaskId}]`, "")
        .replace(`[cover_task_id: ${coverTaskId}]`, "")
        .trim();

      const { error: updateError } = await supabaseAdmin
        .from("tracks")
        .update({
          cover_url: finalCoverUrl,
          description: cleanDesc || null,
        })
        .eq("id", track.id);

      if (updateError) {
        console.error(`Error updating track ${track.id} cover:`, updateError);
      } else {
        console.log(`Track ${track.id} (${track.title}) cover updated: ${finalCoverUrl}`);
        updatedCount++;
      }
    }

    console.log(`Cover callback processed: ${updatedCount} tracks updated`);

    return new Response(
      JSON.stringify({ received: true, success: true, updated: updatedCount }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("suno-cover-callback error:", error);
    return new Response(
      JSON.stringify({
        received: true,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
