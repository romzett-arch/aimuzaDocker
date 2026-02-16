import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Style presets for AI cover generation
const stylePrompts: Record<string, string> = {
  abstract: "Abstract modern art style with flowing shapes, vibrant color gradients, dynamic composition",
  neon: "Neon cyberpunk aesthetic with glowing lights, dark background, electric blue and pink colors, futuristic city vibes",
  minimal: "Minimalist design with clean lines, geometric shapes, limited color palette, elegant simplicity",
  retro: "Retro 80s synthwave style with sunset gradients, palm trees silhouettes, grid patterns, VHS aesthetic",
  nature: "Organic natural elements, forest or ocean imagery, ethereal atmosphere, dreamy soft lighting",
  space: "Cosmic space theme with galaxies, nebulas, stars, planets, deep purple and blue cosmic colors",
  grunge: "Dark grunge aesthetic with textures, distressed elements, moody atmosphere, industrial feel",
  pop_art: "Bold pop art style with bright colors, comic book dots, strong outlines, Andy Warhol inspired",
  watercolor: "Soft watercolor painting style with flowing colors, artistic brushstrokes, delicate textures",
  futuristic: "Futuristic high-tech design with holographic elements, chrome surfaces, AI-generated patterns",
};

const moodPrompts: Record<string, string> = {
  energetic: "high energy, dynamic movement, explosive, powerful",
  calm: "peaceful, serene, tranquil, meditative",
  dark: "mysterious, shadowy, intense, dramatic",
  bright: "cheerful, uplifting, sunny, optimistic",
  melancholic: "emotional, nostalgic, bittersweet, thoughtful",
  aggressive: "fierce, bold, raw, powerful impact",
};

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

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");

    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY is not configured");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Verify user
    const supabaseClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { 
      track_id, 
      track_title, 
      genre,
      style = "abstract",
      mood = "energetic",
      custom_prompt,
      color_scheme,
      include_text = false,
    } = await req.json();

    if (!track_id) {
      return new Response(
        JSON.stringify({ error: "track_id is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Generating AI cover for track: ${track_id}, style: ${style}, mood: ${mood}`);

    // Build the comprehensive prompt
    const styleDescription = stylePrompts[style] || stylePrompts.abstract;
    const moodDescription = moodPrompts[mood] || moodPrompts.energetic;
    
    let prompt = `Create a stunning, professional album cover art (1024x1024 pixels) for a music track.

Track Information:
- Title: "${track_title || 'Untitled'}"
- Genre: ${genre || "electronic music"}

Visual Style: ${styleDescription}
Mood & Atmosphere: ${moodDescription}
${color_scheme ? `Color Palette: ${color_scheme}` : ""}

Requirements:
- Ultra high resolution, professional quality
- Modern, visually striking design suitable for music streaming platforms
- Square 1:1 aspect ratio album artwork
- No text or typography on the image
- Rich details and artistic composition
- Should evoke emotions matching the music style

${custom_prompt ? `Additional creative direction: ${custom_prompt}` : ""}

Create artwork that would stand out on Spotify, Apple Music, and other streaming platforms.`;

    console.log("Prompt:", prompt);

    // Call Lovable AI with image generation
    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-3-pro-image-preview",
        messages: [
          {
            role: "user",
            content: prompt,
          },
        ],
        modalities: ["image", "text"],
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error("AI gateway error:", response.status, errorText);
      
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: "Rate limit exceeded. Please try again later." }),
          { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ error: "Payment required. Please add funds to your workspace." }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      throw new Error(`AI gateway error: ${response.status}`);
    }

    const data = await response.json();
    const imageUrl = data.choices?.[0]?.message?.images?.[0]?.image_url?.url;

    if (!imageUrl) {
      console.error("No image in response:", JSON.stringify(data));
      throw new Error("No image generated by AI");
    }

    console.log("AI cover generated successfully");

    // Upload the base64 image to Supabase Storage
    const base64Data = imageUrl.replace(/^data:image\/\w+;base64,/, "");
    const imageBuffer = Uint8Array.from(atob(base64Data), (c) => c.charCodeAt(0));
    
    const fileName = `ai-covers/${track_id}-${Date.now()}.png`;
    
    const { data: uploadData, error: uploadError } = await supabase.storage
      .from("tracks")
      .upload(fileName, imageBuffer, {
        contentType: "image/png",
        upsert: true,
      });

    if (uploadError) {
      console.error("Storage upload error:", uploadError);
      throw new Error("Failed to upload AI cover to storage");
    }

    const { data: publicUrl } = supabase.storage
      .from("tracks")
      .getPublicUrl(fileName);

    // Store in gallery_items for user's gallery
    await supabase.from("gallery_items").insert({
      user_id: user.id,
      track_id: track_id,
      type: "ai_cover",
      url: publicUrl.publicUrl,
      title: `AI Cover - ${track_title || 'Untitled'}`,
      prompt: prompt,
      style: style,
      is_public: false,
    });

    console.log("Cover saved to gallery:", publicUrl.publicUrl);

    return new Response(
      JSON.stringify({
        success: true,
        cover_url: publicUrl.publicUrl,
        style: style,
        mood: mood,
        message: "AI cover generated successfully",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("generate-ai-cover error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
