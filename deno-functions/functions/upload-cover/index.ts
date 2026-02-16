import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://apibox.erweima.ai";
const FILE_UPLOAD_BASE = "https://sunoapiorg.redpandaai.co";

// Map artist names to genre/style descriptions (Suno doesn't allow artist names)
const artistToStyleMap: Record<string, string> = {
  "Drake": "moody trap hip-hop with melodic hooks",
  "The Weeknd": "dark synth-pop R&B with falsetto vocals",
  "Taylor Swift": "catchy pop-country with storytelling lyrics",
  "Ed Sheeran": "acoustic pop folk with romantic themes",
  "Billie Eilish": "dark minimalist pop with whispered vocals",
  "Ariana Grande": "powerful pop R&B with high vocals",
  "Dua Lipa": "disco-influenced dance pop",
  "Bad Bunny": "reggaeton latin trap with urban beats",
  "Post Malone": "melodic hip-hop rock fusion",
  "Kendrick Lamar": "conscious lyrical hip-hop",
  "Beyoncé": "powerful R&B pop with soulful vocals",
  "Bruno Mars": "funk pop with retro grooves",
  "Adele": "powerful ballads with soulful vocals",
  "Coldplay": "anthemic alternative rock with atmospheric synths",
};

function convertArtistToStyle(artistName: string): string {
  if (artistToStyleMap[artistName]) {
    return artistToStyleMap[artistName];
  }
  const lowerName = artistName.toLowerCase();
  for (const [artist, style] of Object.entries(artistToStyleMap)) {
    if (artist.toLowerCase() === lowerName) {
      return style;
    }
  }
  return "contemporary pop with modern production";
}

function cleanStyleForSuno(style: string): string {
  if (!style) return "";
  
  let cleanedStyle = style;
  for (const artistName of Object.keys(artistToStyleMap)) {
    const regex = new RegExp(`${artistName}\\s*style`, "gi");
    if (regex.test(cleanedStyle)) {
      cleanedStyle = cleanedStyle.replace(regex, convertArtistToStyle(artistName));
    }
    const standaloneRegex = new RegExp(`\\b${artistName}\\b`, "gi");
    if (standaloneRegex.test(cleanedStyle)) {
      cleanedStyle = cleanedStyle.replace(standaloneRegex, convertArtistToStyle(artistName));
    }
  }
  
  cleanedStyle = cleanedStyle.replace(/,\s*,/g, ",").replace(/\s+/g, " ").trim();
  return cleanedStyle;
}

/**
 * Upload file to Suno API via URL method
 */
async function uploadFileToSuno(fileUrl: string): Promise<string> {
  console.log(`Uploading file to Suno from URL: ${fileUrl}`);
  
  // Send both parameter names for API compatibility
  const requestBody = { 
    fileUrl: fileUrl,
    uploadPath: fileUrl,
    url: fileUrl 
  };
  console.log("Upload request body:", JSON.stringify(requestBody));
  
  const response = await fetch(`${FILE_UPLOAD_BASE}/api/file-url-upload`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${SUNO_API_KEY}`,
    },
    body: JSON.stringify(requestBody),
  });

  const data = await response.json();
  console.log("File upload response:", JSON.stringify(data));
  
  if (!response.ok || (data.code && data.code !== 200)) {
    throw new Error(data.msg || "Failed to upload file to Suno");
  }
  
  // Response contains downloadUrl for the uploaded file
  const uploadedUrl = data.data?.downloadUrl || data.data?.url || data.data || data.downloadUrl || data.url;
  console.log("Uploaded file URL:", uploadedUrl);
  return uploadedUrl;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "No authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { 
      trackId, 
      sourceAudioUrl,  // URL of uploaded audio file (from Supabase storage or external)
      prompt,          // Lyrics or description
      style,           // Music style
      title, 
      instrumental,
      customMode = true,
    } = await req.json();

    if (!trackId || !sourceAudioUrl) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: trackId, sourceAudioUrl" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Starting upload-cover for track ${trackId} by user ${user.id}`);
    console.log(`Source audio: ${sourceAudioUrl}`);
    console.log(`Style: ${style}, Instrumental: ${instrumental}`);

    // Clean the style to remove artist names
    const cleanedStyle = cleanStyleForSuno(style || "");
    console.log(`Cleaned style: ${cleanedStyle}`);

    // Update track status to processing
    const { error: updateError } = await supabaseClient
      .from("tracks")
      .update({ status: "processing", error_message: null })
      .eq("id", trackId)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("Failed to update track status:", updateError);
    }

    // Step 1: Upload the source audio to Suno's servers
    let sunoUploadUrl: string;
    try {
      sunoUploadUrl = await uploadFileToSuno(sourceAudioUrl);
      console.log(`File uploaded to Suno: ${sunoUploadUrl}`);
    } catch (uploadError) {
      console.error("Failed to upload file to Suno:", uploadError);
      await supabaseClient
        .from("tracks")
        .update({ 
          status: "failed",
          error_message: "Не удалось загрузить аудио для обработки"
        })
        .eq("id", trackId);
      
      return new Response(
        JSON.stringify({ error: "Failed to upload audio file" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Step 2: Call Suno upload-cover endpoint
    const sunoPayload: Record<string, unknown> = {
      uploadUrl: sunoUploadUrl,
      customMode: customMode,
      instrumental: instrumental || false,
      model: "V4",
      callBackUrl: `${Deno.env.get("SUPABASE_URL")}/functions/v1/suno-callback`,
    };

    if (customMode) {
      if (prompt) sunoPayload.prompt = prompt;
      if (cleanedStyle) sunoPayload.style = cleanedStyle;
      if (title) sunoPayload.title = title;
    }

    console.log("Sending to Suno upload-cover API:", JSON.stringify(sunoPayload));

    const sunoResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/upload-cover`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    console.log("Suno upload-cover response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      const errorMessage = sunoData.msg || "Failed to start cover generation";
      console.error(`Suno API error: ${errorMessage}`);
      
      await supabaseClient
        .from("tracks")
        .update({ 
          status: "failed",
          error_message: errorMessage
        })
        .eq("id", trackId)
        .eq("user_id", user.id);

      return new Response(
        JSON.stringify({ 
          error: errorMessage,
          details: sunoData 
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const taskId = sunoData.data?.taskId;
    console.log(`Cover generation started with task ID: ${taskId}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        taskId,
        message: "Cover generation started successfully" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in upload-cover:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
