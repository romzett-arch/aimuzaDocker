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

  try {
    // Security: Verify request comes from authenticated user or service role
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    
    // Check if called by service role (from other edge functions) or validate user
    const isServiceRole = authHeader === `Bearer ${supabaseServiceKey}`;
    
    if (!isServiceRole) {
      // Validate user auth
      const userClient = createClient(supabaseUrl, supabaseAnonKey, {
        global: { headers: { Authorization: authHeader } }
      });
      const { data: { user }, error: userError } = await userClient.auth.getUser();
      if (userError || !user) {
        return new Response(
          JSON.stringify({ error: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    const { separation_id, type, source_url } = await req.json();
    console.log("Audio separation request:", { separation_id, type, source_url });

    if (!separation_id || !type || !source_url) {
      return new Response(
        JSON.stringify({ error: "Missing required fields" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Update status to processing
    await supabase
      .from("audio_separations")
      .update({ status: "processing" })
      .eq("id", separation_id);

    console.log("Updated separation status to processing");

    // Start background processing using the event loop
    // The function will continue running after the response is sent
    (async () => {
      await processAudioSeparation(supabase, separation_id, type, source_url);
    })();

    return new Response(
      JSON.stringify({ success: true, message: "Processing started" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Audio separation error:", error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

async function processAudioSeparation(
  supabase: any,
  separationId: string,
  type: "vocal" | "stems",
  sourceUrl: string
) {
  try {
    console.log("Starting audio separation processing:", { separationId, type });

    // Get the SUNO_API_KEY for audio separation
    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    // Call the Suno API for audio separation
    // Note: This is a placeholder for the actual Suno vocal-removal/stems API
    // The actual endpoint and request format may vary based on Suno's API documentation
    
    let endpoint = "";
    let requestBody: any = {};
    
    if (type === "vocal") {
      // Vocal separation - separate vocals from instrumentals
      endpoint = "https://apibox.erweima.ai/api/v1/suno/vocal-removal/generate";
      requestBody = {
        audio_url: sourceUrl,
      };
    } else {
      // Stem separation - separate into individual instruments
      endpoint = "https://apibox.erweima.ai/api/v1/suno/stem-separation/generate";
      requestBody = {
        audio_url: sourceUrl,
        stems: ["drums", "bass", "guitar", "piano", "other"],
      };
    }

    console.log("Calling separation API:", endpoint);

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${SUNO_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error("Separation API error:", response.status, errorText);
      throw new Error(`API error: ${response.status}`);
    }

    const result = await response.json();
    console.log("Separation API response:", result);

    // Check if we got a task ID for polling
    if (result.data?.task_id) {
      // Poll for completion
      const completedResult = await pollForCompletion(SUNO_API_KEY, result.data.task_id, type);
      
      // Update the separation record with results
      await supabase
        .from("audio_separations")
        .update({
          status: "completed",
          result_urls: completedResult,
        })
        .eq("id", separationId);
        
      console.log("Separation completed successfully");
    } else if (result.data?.urls || result.urls) {
      // Direct result
      const urls = result.data?.urls || result.urls;
      
      await supabase
        .from("audio_separations")
        .update({
          status: "completed",
          result_urls: urls,
        })
        .eq("id", separationId);
        
      console.log("Separation completed successfully with direct result");
    } else {
      throw new Error("Unexpected API response format");
    }
  } catch (error) {
    console.error("Processing error:", error);
    
    // Update status to failed
    await supabase
      .from("audio_separations")
      .update({
        status: "failed",
        error_message: error instanceof Error ? error.message : "Unknown error",
      })
      .eq("id", separationId);
  }
}

async function pollForCompletion(
  apiKey: string,
  taskId: string,
  type: "vocal" | "stems",
  maxAttempts = 60,
  intervalMs = 5000
): Promise<Record<string, string>> {
  const endpoint = type === "vocal"
    ? `https://apibox.erweima.ai/api/v1/suno/vocal-removal/status/${taskId}`
    : `https://apibox.erweima.ai/api/v1/suno/stem-separation/status/${taskId}`;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    console.log(`Polling attempt ${attempt + 1}/${maxAttempts}`);
    
    const response = await fetch(endpoint, {
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
    });

    if (!response.ok) {
      console.error("Poll error:", response.status);
      throw new Error(`Poll error: ${response.status}`);
    }

    const result = await response.json();
    console.log("Poll result:", result);

    if (result.data?.status === "completed" || result.status === "completed") {
      // Return the URLs
      return result.data?.urls || result.urls || {};
    }

    if (result.data?.status === "failed" || result.status === "failed") {
      throw new Error(result.data?.error || result.error || "Processing failed");
    }

    // Wait before next poll
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }

  throw new Error("Timeout waiting for separation to complete");
}
