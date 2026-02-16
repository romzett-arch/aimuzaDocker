import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_API_BASE = "https://apibox.erweima.ai";

// Human-readable error messages for Suno error codes (Russian)
// Official Suno API error codes:
// 400 - Invalid Parameters, 401 - Unauthorized, 403 - Forbidden (moderation)
// 404 - Not Found, 405 - Rate Limited, 413 - Content Too Large
// 429 - Insufficient Credits, 455 - Maintenance, 500/503 - Server errors
function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  // First, check for specific error message patterns (more accurate than code)
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();
    
    if (lowerMsg.includes("matches existing work") || 
        lowerMsg.includes("existing work of art") ||
        lowerMsg.includes("copyright") ||
        lowerMsg.includes("protected content")) {
      return {
        short: "Контент защищён авторским правом",
        full: "Загруженный аудиофайл или текст распознан как существующее произведение. Попробуйте использовать оригинальный контент."
      };
    }
    
    if (lowerMsg.includes("moderation") || 
        lowerMsg.includes("sensitive") || 
        lowerMsg.includes("inappropriate") ||
        lowerMsg.includes("prohibited")) {
      return {
        short: "Контент не прошёл модерацию",
        full: "Текст или описание содержит запрещённые слова. Измените содержимое и попробуйте снова."
      };
    }
    
    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Сократите текст и попробуйте снова."
      };
    }
    
    if (lowerMsg.includes("credit") || lowerMsg.includes("balance") || lowerMsg.includes("insufficient")) {
      return {
        short: "Недостаточно кредитов Suno",
        full: "На аккаунте Suno недостаточно кредитов для генерации. Обратитесь в поддержку."
      };
    }
  }

  const errorMessages: Record<number, { short: string; full: string }> = {
    400: { short: "Неверные параметры запроса", full: "Проверьте введённые данные и попробуйте снова." },
    401: { short: "Ошибка авторизации", full: "Проблема с авторизацией в сервисе Suno. Обратитесь в поддержку." },
    403: { short: "Контент заблокирован", full: "Запрос содержит запрещённый контент. Измените текст или описание." },
    404: { short: "Ресурс не найден", full: "Запрашиваемый ресурс не найден. Попробуйте ещё раз." },
    405: { short: "Превышена частота запросов", full: "Слишком много запросов. Подождите несколько минут." },
    413: { short: "Превышен лимит символов", full: "Текст слишком длинный (макс. ~3000 символов для lyrics). Сократите и попробуйте снова." },
    429: { short: "Недостаточно кредитов", full: "На аккаунте Suno недостаточно кредитов. Обратитесь в поддержку." },
    455: { short: "Сервис на обслуживании", full: "Suno проходит техническое обслуживание. Попробуйте позже." },
    500: { short: "Ошибка сервера Suno", full: "Внутренняя ошибка на сервере Suno. Попробуйте позже." },
    503: { short: "Сервис недоступен", full: "Suno временно перегружен. Попробуйте позже." }
  };
  
  if (errorMessages[code]) {
    return errorMessages[code];
  }
  
  return {
    short: `Ошибка генерации (код ${code})`,
    full: originalMessage || `Произошла ошибка при генерации. Код: ${code}`
  };
}

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
  "BTS": "K-pop with dynamic choreography vibes",
  "Harry Styles": "70s inspired soft rock pop",
  "Doja Cat": "playful rap-pop with catchy hooks",
  "SZA": "neo-soul R&B with vulnerable lyrics",
  "Travis Scott": "atmospheric auto-tune trap",
  "Olivia Rodrigo": "emotional pop-rock with teen angst",
  "Lana Del Rey": "cinematic dreamy baroque pop",
  "Kanye West": "experimental hip-hop with gospel influences",
  "Bruno Mars": "funk pop with retro grooves",
  "Adele": "powerful ballads with soulful vocals",
  "Rihanna": "dancehall-influenced pop R&B",
  "Justin Bieber": "pop R&B with tropical influences",
  "Lady Gaga": "theatrical electro-pop",
  "Shakira": "latin pop with world music fusion",
  "Coldplay": "anthemic alternative rock with atmospheric synths",
  "Imagine Dragons": "arena rock with electronic elements",
  "Twenty One Pilots": "alternative hip-hop with electronic elements",
  "Maroon 5": "pop rock with funky grooves",
  "OneRepublic": "orchestral pop rock with uplifting themes",
};

// Convert artist name to safe style description
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

// Clean style string to remove artist names
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

    // Also create admin client for creating notifications
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // P0 FIX: Check if user is blocked before allowing generation
    const { data: isBlocked } = await supabaseAdmin.rpc("is_user_blocked", { p_user_id: user.id });
    if (isBlocked) {
      return new Response(
        JSON.stringify({ error: "Ваш аккаунт заблокирован. Генерация недоступна." }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { trackId, prompt, lyrics, style, title, instrumental, audioReferenceUrl, useBoostStyle } = await req.json();

    if (!trackId || !prompt) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: trackId, prompt" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Starting generation for track ${trackId} by user ${user.id}, model: ${useBoostStyle ? "V4.5 Plus" : "V5"}`);
    console.log(`Original prompt: ${prompt}`);
    console.log(`Original style: ${style}`);
    console.log(`Instrumental: ${instrumental}`);
    console.log(`Audio reference URL: ${audioReferenceUrl || 'none'}`);

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

    // Build the Suno API payload according to documentation
    const hasLyrics = !!lyrics && lyrics.trim().length > 0;
    const hasStyle = !!cleanedStyle && cleanedStyle.trim().length > 0;
    const hasPrompt = !!prompt && prompt.trim().length > 0;
    const useCustomMode = hasLyrics || hasStyle;

    // Clean the prompt (description) as well
    const cleanedPrompt = cleanStyleForSuno(prompt || "");
    console.log(`Cleaned prompt (description): ${cleanedPrompt}`);

    // Build callback URL with secret for security
    // Use SUNO_CALLBACK_URL if set (should be public URL), otherwise fall back to SUPABASE_URL
    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    const explicitCallbackUrl = Deno.env.get("SUNO_CALLBACK_URL");
    const baseCallbackUrl = explicitCallbackUrl || `${Deno.env.get("SUPABASE_URL")}/functions/v1/suno-callback`;
    const callBackUrl = callbackSecret 
      ? `${baseCallbackUrl}${baseCallbackUrl.includes('?') ? '&' : '?'}secret=${encodeURIComponent(callbackSecret)}`
      : baseCallbackUrl;
    console.log(`Callback URL: ${callBackUrl}`);

    // V5 по умолчанию, V4.5 Plus при boost-style (пользователь не видит версию)
    const sunoModel = useBoostStyle ? "V4.5 Plus" : "V5";
    const styleCharLimit = 1000; // V4.5/V5 поддерживают до 1000 символов в style

    const sunoPayload: Record<string, any> = {
      model: sunoModel,
      customMode: useCustomMode,
      instrumental: instrumental || false,
      callBackUrl,
    };

    if (useCustomMode) {
      // prompt field = lyrics (if present) or description
      sunoPayload.prompt = hasLyrics ? lyrics : prompt;
      
      // CRITICAL: style field should ONLY contain genre/vocal/style tags - NOT the description!
      // Suno has a strict 200 character limit on style field
      // Description goes in the prompt, not in style
      let finalStyle = cleanedStyle || "pop";
      
      // Truncate style to limit (V4.5/V5: 1000 chars)
      if (finalStyle.length > styleCharLimit) {
        const parts = finalStyle.split(", ");
        let truncated = "";
        for (const part of parts) {
          if ((truncated + ", " + part).length <= styleCharLimit) {
            truncated = truncated ? truncated + ", " + part : part;
          } else {
            break;
          }
        }
        finalStyle = truncated || finalStyle.slice(0, styleCharLimit);
        console.log(`Style truncated from ${cleanedStyle.length} to ${finalStyle.length} chars`);
      }
      
      sunoPayload.style = finalStyle;
      sunoPayload.title = title || "Untitled";
      
      console.log(`Final style for Suno (${sunoPayload.style.length} chars): ${sunoPayload.style}`);
    } else {
      sunoPayload.prompt = prompt.slice(0, 400);
    }

    // Determine which endpoint to use
    let sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate`;
    
    // If audio reference is provided, use upload-cover endpoint instead
    if (audioReferenceUrl) {
      sunoEndpoint = `${SUNO_API_BASE}/api/v1/generate/upload-cover`;
      sunoPayload.uploadUrl = audioReferenceUrl;
      console.log("Using upload-cover endpoint with audio reference");
    }

    console.log("Sending to Suno API:", JSON.stringify(sunoPayload));
    console.log("Endpoint:", sunoEndpoint);

    const sunoResponse = await fetch(sunoEndpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(sunoPayload),
    });

    const sunoData = await sunoResponse.json();
    console.log("Suno API response:", JSON.stringify(sunoData));

    if (!sunoResponse.ok || sunoData.code !== 200) {
      const rawErrorMessage = sunoData.msg || "Failed to start generation";
      const errorCode = sunoData.code || sunoResponse.status || 500;
      
      // Get human-readable Russian error message
      const errorInfo = getSunoErrorMessage(errorCode, rawErrorMessage);
      const russianErrorMessage = errorInfo.short;
      
      console.error(`Suno API error (${errorCode}): ${rawErrorMessage} -> ${russianErrorMessage}`);
      
      // Update track status to failed with Russian error message
      await supabaseClient
        .from("tracks")
        .update({ 
          status: "failed",
          error_message: russianErrorMessage
        })
        .eq("id", trackId)
        .eq("user_id", user.id);

      // Get all tracks with this base title to find paired track
      const { data: allTracks } = await supabaseClient
        .from("tracks")
        .select("id")
        .eq("user_id", user.id)
        .in("status", ["pending", "processing"]);

      const trackIds = allTracks?.map(t => t.id) || [trackId];

      // Refund: update generation_logs to failed and return balance
      const { data: logs } = await supabaseClient
        .from("generation_logs")
        .select("id, cost_rub")
        .in("track_id", trackIds)
        .eq("user_id", user.id)
        .eq("status", "pending");

      let totalRefund = 0;
      if (logs && logs.length > 0) {
        totalRefund = logs.reduce((sum, log) => sum + (log.cost_rub || 0), 0);
        
        // Mark logs as failed
        await supabaseClient
          .from("generation_logs")
          .update({ status: "failed" })
          .in("id", logs.map(l => l.id));

        // Refund the balance
        if (totalRefund > 0) {
          const { data: profile } = await supabaseClient
            .from("profiles")
            .select("balance")
            .eq("user_id", user.id)
            .single();

          if (profile) {
            const newBalance = (profile.balance || 0) + totalRefund;
            await supabaseClient
              .from("profiles")
              .update({ balance: newBalance })
              .eq("user_id", user.id);
            
            // Log refund transaction
            await supabaseClient.from("balance_transactions").insert({
              user_id: user.id,
              amount: totalRefund,
              balance_after: newBalance,
              type: "refund",
              description: `Возврат за неудачную генерацию`,
              reference_id: trackId,
              reference_type: "track",
              metadata: { error: russianErrorMessage },
            });
            
            console.log(`Refunded ${totalRefund} to user ${user.id}`);
          }
        }
      }

      // Also mark other pending tracks as failed
      await supabaseClient
        .from("tracks")
        .update({ status: "failed", error_message: russianErrorMessage })
        .eq("user_id", user.id)
        .in("status", ["pending", "processing"]);

      // Create notification for refund with Russian error explanation
      if (totalRefund > 0) {
        await supabaseAdmin
          .from("notifications")
          .insert({
            user_id: user.id,
            type: "refund",
            title: `Ошибка: ${russianErrorMessage}`,
            message: `${errorInfo.full}\n\nВам возвращено ${totalRefund} ₽`,
            target_type: "track",
            target_id: trackId,
          });
      }

      return new Response(
        JSON.stringify({ 
          error: russianErrorMessage,
          details: errorInfo.full,
          refunded: totalRefund > 0,
          refundAmount: totalRefund
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const taskId = sunoData.data?.taskId;
    console.log(`Generation started with task ID: ${taskId}`);

    // CRITICAL: Store task_id in description for ONLY the current track pair (v1 and v2)
    // This is essential for the callback to match results to the correct tracks
    // DO NOT update other pending tracks - they have their own task_id from their own generation!
    if (taskId) {
      // Get the current track's info including created_at to find its pair
      const { data: currentTrack } = await supabaseClient
        .from("tracks")
        .select("id, title, description, created_at")
        .eq("id", trackId)
        .single();
      
      if (currentTrack) {
        // Find the paired track: same base title, same user, created within 5 seconds
        const baseTitle = (currentTrack.title || "").replace(/\s*\(v\d+\)$/, "").trim();
        const createdAt = new Date(currentTrack.created_at);
        const windowStart = new Date(createdAt.getTime() - 5000).toISOString();
        const windowEnd = new Date(createdAt.getTime() + 5000).toISOString();
        
        const { data: pairedTracks } = await supabaseClient
          .from("tracks")
          .select("id, title, description, created_at")
          .eq("user_id", user.id)
          .gte("created_at", windowStart)
          .lte("created_at", windowEnd);
        
        const filtered = pairedTracks?.filter(t => {
          const tBaseTitle = (t.title || "").replace(/\s*\(v\d+\)$/, "").trim();
          return tBaseTitle === baseTitle;
        }) || [];
        
        // CRITICAL FIX: empty array is truthy, so check .length explicitly
        const tracksToUpdate = filtered.length > 0 ? filtered : [currentTrack];
        
        console.log(`Found ${tracksToUpdate.length} tracks in pair to update with task_id (filtered: ${filtered.length}, paired: ${pairedTracks?.length || 0})`);
        
        for (const track of tracksToUpdate) {
          // IMPORTANT: Only update if this track doesn't already have a task_id
          // This prevents overwriting task_id from a different generation
          if (track.description?.includes("[task_id:")) {
            console.log(`Track ${track.id} (${track.title}) already has task_id, skipping to prevent overwrite`);
            continue;
          }
          
          // Append task_id to description (preserve existing content)
          const existingDesc = track.description || "";
          const newDesc = existingDesc 
            ? `${existingDesc}\n\n[task_id: ${taskId}]`
            : `[task_id: ${taskId}]`;
          
          await supabaseClient
            .from("tracks")
            .update({ description: newDesc })
            .eq("id", track.id);
          
          console.log(`Stored task_id ${taskId} in track ${track.id} (${track.title})`);
        }
      } else {
        // Fallback: at least update the current track
        const newDesc = `[task_id: ${taskId}]`;
        
        await supabaseClient
          .from("tracks")
          .update({ description: newDesc })
          .eq("id", trackId);
        
        console.log(`Stored task_id ${taskId} in track ${trackId} (fallback)`);
      }
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        taskId,
        message: "Generation started successfully" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in suno-generate:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: "Произошла непредвиденная ошибка. Попробуйте позже." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});