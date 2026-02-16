import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://apibox.erweima.ai";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
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

    const token = authHeader.replace("Bearer ", "");
    const { data: claimsData, error: claimsError } = await supabaseClient.auth.getClaims(token);
    
    if (claimsError || !claimsData?.claims?.sub) {
      console.error("Auth error:", claimsError);
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const userId = claimsData.claims.sub;

    // Check if user is admin using the is_admin function
    const { data: isAdmin } = await supabaseClient.rpc("is_admin", { _user_id: userId });
    
    if (!isAdmin) {
      return new Response(
        JSON.stringify({ error: "Access denied. Admin only." }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Admin ${userId} requesting Suno credits balance`);

    // Fetch credits from Suno API
    const sunoResponse = await fetch(`${SUNO_API_BASE}/api/v1/generate/credit`, {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
    });

    // Check if response is JSON before parsing
    const contentType = sunoResponse.headers.get("content-type") || "";
    if (!contentType.includes("application/json")) {
      const text = await sunoResponse.text();
      console.error("Suno API returned non-JSON:", text.substring(0, 200));
      return new Response(
        JSON.stringify({ 
          error: "Suno API unavailable",
          details: `Status: ${sunoResponse.status}, returned HTML instead of JSON`
        }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const sunoData = await sunoResponse.json();
    console.log("Suno credits response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      console.error("Suno API error:", sunoData);
      return new Response(
        JSON.stringify({ 
          error: "Failed to fetch Suno credits",
          details: sunoData.msg || "Unknown error"
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const credits = sunoData.data;
    console.log(`Suno credits remaining: ${credits}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        credits: credits
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in suno-credits:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
