import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "./types.ts";
import { translateMusicPrompt } from "./prompts.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { content } = await req.json();
    console.log("Boost style request:", { content });

    const translatedContent = translateMusicPrompt(content);
    console.log("Translated content:", translatedContent);

    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    const response = await fetch("https://api.sunoapi.org/api/v1/style/generate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify({
        content: translatedContent,
      }),
    });

    const result = await response.json();
    console.log("Suno Style Boost API response:", result);

    if (result.code !== 200) {
      console.log("Suno API failed, returning translated content");
      return new Response(
        JSON.stringify({
          success: true,
          boostedStyle: translatedContent,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const boostedStyle = result.data?.result || result.data?.style || result.data?.content;

    if (boostedStyle) {
      return new Response(
        JSON.stringify({
          success: true,
          boostedStyle,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        boostedStyle: translatedContent,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in boost-style:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
