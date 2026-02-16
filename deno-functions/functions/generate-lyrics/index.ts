import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Poll for lyrics result
async function pollLyricsResult(taskId: string, apiKey: string, maxAttempts = 30): Promise<{ text: string; title: string } | null> {
  for (let i = 0; i < maxAttempts; i++) {
    await new Promise(resolve => setTimeout(resolve, 2000)); // Wait 2 seconds between polls
    
    try {
      const response = await fetch(`https://api.sunoapi.org/api/v1/lyrics/record-info?taskId=${taskId}`, {
        headers: {
          "Authorization": `Bearer ${apiKey}`,
        },
      });
      
      const result = await response.json();
      console.log(`Poll attempt ${i + 1}:`, result);
      
      if (result.code === 200 && result.data?.status === "SUCCESS") {
        // API returns an array of results in result.data.response.data
        const lyricsData = result.data.response?.data;
        if (lyricsData && lyricsData.length > 0) {
          return {
            text: lyricsData[0].text || "",
            title: lyricsData[0].title || "",
          };
        }
        // Fallback to direct fields if available
        return {
          text: result.data.text || "",
          title: result.data.title || "",
        };
      }
      
      if (result.data?.status === "FAILED") {
        throw new Error("Lyrics generation failed");
      }
    } catch (error) {
      console.error("Poll error:", error);
    }
  }
  return null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // CRITICAL: Authenticate user from token
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Необходима авторизация" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Verify JWT and get authenticated user using getUser (works with modern Supabase)
    const token = authHeader.replace("Bearer ", "");
    const { data: { user: authUser }, error: authError } = await supabase.auth.getUser(token);
    
    if (authError || !authUser?.id) {
      console.error("Auth error:", authError);
      return new Response(
        JSON.stringify({ error: "Неверный токен авторизации" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Use authenticated user ID, NOT from request body
    const user_id = authUser.id;
    
    const { prompt } = await req.json();
    
    console.log("Generate lyrics request:", { prompt, user_id });

    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    if (!SUNO_API_KEY) {
      throw new Error("SUNO_API_KEY not configured");
    }

    // Get service price
    const { data: service } = await supabase
      .from("addon_services")
      .select("price_rub")
      .eq("name", "generate_lyrics")
      .maybeSingle();

    const price = service?.price_rub || 4;

    // Check user balance
    const { data: profile } = await supabase
      .from("profiles")
      .select("balance")
      .eq("user_id", user_id)
      .maybeSingle();

    if (!profile || (profile.balance || 0) < price) {
      throw new Error("Недостаточно средств на балансе");
    }

    // Deduct balance
    const newBalance = (profile.balance || 0) - price;
    await supabase
      .from("profiles")
      .update({ balance: newBalance })
      .eq("user_id", user_id);

    // Log transaction
    await supabase.from("balance_transactions").insert({
      user_id: user_id,
      amount: -price,
      balance_after: newBalance,
      type: "lyrics_gen",
      description: "Генерация текста (Suno)",
    });

    // Call Suno API to generate lyrics
    // Note: callBackUrl is required by API, but we'll poll for results
    const callbackUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/lyrics-callback`;
    const response = await fetch("https://api.sunoapi.org/api/v1/lyrics", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify({
        prompt,
        callBackUrl: callbackUrl,
      }),
    });

    const result = await response.json();
    console.log("Suno Lyrics API response:", result);

    if (result.code !== 200) {
      // Refund on failure
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user_id);
      throw new Error(result.msg || "Failed to generate lyrics");
    }

    const taskId = result.data?.taskId;
    if (!taskId) {
      // Refund on failure
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user_id);
      throw new Error("No taskId returned from API");
    }

    // Poll for result
    const lyricsResult = await pollLyricsResult(taskId, SUNO_API_KEY);
    
    if (!lyricsResult) {
      // Refund on timeout
      await supabase
        .from("profiles")
        .update({ balance: profile.balance })
        .eq("user_id", user_id);
      throw new Error("Timeout waiting for lyrics generation");
    }

    // Save to history
    await supabase
      .from("generated_lyrics")
      .insert({
        user_id: user_id,
        prompt: prompt,
        lyrics: lyricsResult.text,
        title: lyricsResult.title || null,
      });

    return new Response(
      JSON.stringify({ 
        success: true, 
        lyrics: lyricsResult.text,
        title: lyricsResult.title,
        message: "Текст успешно сгенерирован" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in generate-lyrics:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});