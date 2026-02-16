import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Background task helper — fire-and-forget pattern
// (EdgeRuntime.waitUntil is NOT available in this Deno server)
function runInBackground(taskName: string, promise: Promise<unknown>): void {
  promise.catch(err => console.error(`[Background: ${taskName}] Error:`, err));
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Helper function to download file and upload to Supabase Storage
async function copyFileToStorage(
  supabaseAdmin: SupabaseClient,
  externalUrl: string,
  bucket: string,
  filePath: string
): Promise<string | null> {
  try {
    console.log(`Downloading file from: ${externalUrl}`);
    
    const response = await fetch(externalUrl);
    if (!response.ok) {
      console.error(`Failed to download: ${response.status} ${response.statusText}`);
      return null;
    }

    const blob = await response.blob();
    const arrayBuffer = await blob.arrayBuffer();
    const uint8Array = new Uint8Array(arrayBuffer);
    
    console.log(`Downloaded ${uint8Array.length} bytes, uploading to ${bucket}/${filePath}`);

    const { error: uploadError } = await supabaseAdmin.storage
      .from(bucket)
      .upload(filePath, uint8Array, {
        contentType: blob.type || "application/octet-stream",
        upsert: true,
      });

    if (uploadError) {
      console.error(`Upload error:`, uploadError);
      return null;
    }

    // Build public URL using BASE_URL (not internal SUPABASE_URL which is http://api:3000)
    const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    const publicUrl = `${baseUrl}/storage/v1/object/public/${bucket}/${filePath}`;

    console.log(`File uploaded successfully: ${publicUrl}`);
    return publicUrl;
    
  } catch (err) {
    console.error(`Error copying file to storage:`, err);
    return null;
  }
}

// Timeweb Agent API configuration for AI classification
const TIMEWEB_AGENT_ACCESS_ID = 'e046a9e4-43f6-47bc-a39f-8a9de8778d02';

// AI Classification function - determines genre, vocal type, template, artist style
// Uses Timeweb Agent API (GPT-4)
async function classifyTrackWithAI(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  style: string | null,
  lyrics: string | null
) {
  try {
    console.log(`Starting AI classification for track ${trackId}`);
    
    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      console.error("TIMEWEB_AGENT_TOKEN not configured, skipping classification");
      return;
    }
    
    // Fetch all available options from database
    const [genresRes, vocalTypesRes, templatesRes, artistStylesRes] = await Promise.all([
      supabaseAdmin.from("genres").select("id, name, name_ru").order("sort_order"),
      supabaseAdmin.from("vocal_types").select("id, name, name_ru, description").eq("is_active", true).order("sort_order"),
      supabaseAdmin.from("templates").select("id, name, description").eq("is_active", true).order("sort_order"),
      supabaseAdmin.from("artist_styles").select("id, name, description").eq("is_active", true).order("sort_order"),
    ]);
    
    const genres = genresRes.data || [];
    const vocalTypes = vocalTypesRes.data || [];
    const templates = templatesRes.data || [];
    const artistStyles = artistStylesRes.data || [];
    
    if (genres.length === 0) {
      console.log("No genres in database, skipping classification");
      return;
    }
    
    // Build the classification prompt
    const genresList = genres.map(g => `- id: "${g.id}", name: "${g.name}" (${g.name_ru})`).join("\n");
    const vocalTypesList = vocalTypes.map(v => `- id: "${v.id}", name: "${v.name}" (${v.name_ru})${v.description ? ` - ${v.description}` : ""}`).join("\n");
    const templatesList = templates.length > 0 
      ? templates.map(t => `- id: "${t.id}", name: "${t.name}"${t.description ? ` - ${t.description}` : ""}`).join("\n")
      : "Нет доступных шаблонов";
    const artistStylesList = artistStyles.length > 0
      ? artistStyles.map(a => `- id: "${a.id}", name: "${a.name}"${a.description ? ` - ${a.description}` : ""}`).join("\n")
      : "Нет доступных стилей артистов";
    
    const prompt = `Ты — музыкальный классификатор. Проанализируй стиль и лирику трека.
Выбери ОДИН наиболее подходящий вариант из каждой категории.

ЖАНРЫ (обязательно выбери один):
${genresList}

ТИПЫ ВОКАЛА (обязательно выбери один):
${vocalTypesList}

ШАБЛОНЫ (опционально, выбери если подходит):
${templatesList}

СТИЛИ АРТИСТОВ (опционально, выбери если есть явное сходство):
${artistStylesList}

---
СТИЛЬ ТРЕКА: ${style || "Не указан"}
ЛИРИКА: ${lyrics ? lyrics.substring(0, 1000) : "Инструментал (без текста)"}
---

Правила:
1. genre_id - ОБЯЗАТЕЛЕН, выбери наиболее близкий жанр
2. vocal_type_id - ОБЯЗАТЕЛЕН. Если нет лирики, выбери "instrumental"
3. template_id - только если трек явно соответствует шаблону, иначе null
4. artist_style_id - только если стиль явно похож на конкретного артиста, иначе null

Верни ТОЛЬКО JSON без markdown:
{"genre_id": "...", "vocal_type_id": "...", "template_id": "..." или null, "artist_style_id": "..." или null}`;

    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;
    
    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
        "Content-Type": "application/json",
        "x-proxy-source": "lovable-app",
      },
      body: JSON.stringify({
        model: "deepseek-v3.2",
        messages: [
          { role: "system", content: "Ты музыкальный классификатор. Отвечай только JSON." },
          { role: "user", content: prompt }
        ],
        temperature: 0.3,
      }),
    });

    if (!response.ok) {
      console.error(`AI classification failed: ${response.status}`);
      return;
    }

    const result = await response.json();
    const content = result.choices?.[0]?.message?.content;
    
    if (!content) {
      console.error("No content in AI response");
      return;
    }
    
    console.log(`AI classification response: ${content}`);
    
    // Parse JSON response (handle potential markdown wrapper)
    let classification;
    try {
      const jsonMatch = content.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        classification = JSON.parse(jsonMatch[0]);
      } else {
        classification = JSON.parse(content);
      }
    } catch (parseErr) {
      console.error("Failed to parse AI classification:", parseErr);
      return;
    }
    
    // Validate IDs exist in our data
    const validGenreId = genres.find(g => g.id === classification.genre_id)?.id || null;
    const validVocalTypeId = vocalTypes.find(v => v.id === classification.vocal_type_id)?.id || null;
    const validTemplateId = classification.template_id 
      ? templates.find(t => t.id === classification.template_id)?.id || null 
      : null;
    const validArtistStyleId = classification.artist_style_id 
      ? artistStyles.find(a => a.id === classification.artist_style_id)?.id || null 
      : null;
    
    // Update track with classification
    const updateData: Record<string, string | null> = {};
    if (validGenreId) updateData.genre_id = validGenreId;
    if (validVocalTypeId) updateData.vocal_type_id = validVocalTypeId;
    if (validTemplateId) updateData.template_id = validTemplateId;
    if (validArtistStyleId) updateData.artist_style_id = validArtistStyleId;
    
    if (Object.keys(updateData).length > 0) {
      const { error: updateErr } = await supabaseAdmin
        .from("tracks")
        .update(updateData)
        .eq("id", trackId);
      
      if (updateErr) {
        console.error("Failed to update track classification:", updateErr);
      } else {
        console.log(`Track ${trackId} classified: genre=${validGenreId}, vocal=${validVocalTypeId}, template=${validTemplateId}, artist=${validArtistStyleId}`);
      }
    }
  } catch (err) {
    console.error("Error in AI classification:", err);
  }
}

// Function to process addon services after track is completed
async function processTrackAddons(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  trackTitle: string,
  coverUrl: string | null,
  audioUrl: string | null,
  sunoTaskId?: string,
  sunoAudioId?: string
) {
  try {
    // Get pending addons for this track
    const { data: trackAddons, error: addonsError } = await supabaseAdmin
      .from("track_addons")
      .select(`
        id,
        addon_service_id,
        status,
        addon_service:addon_services(name, name_ru)
      `)
      .eq("track_id", trackId)
      .eq("status", "pending");

    if (addonsError) {
      console.error("Error fetching track addons:", addonsError);
      return;
    }

    if (!trackAddons || trackAddons.length === 0) {
      console.log(`No pending addons for track ${trackId}`);
      return;
    }

    console.log(`Processing ${trackAddons.length} addons for track ${trackId}`);

    // Get track genre for better AI generation
    const { data: track } = await supabaseAdmin
      .from("tracks")
      .select("genre_id, genres(name)")
      .eq("id", trackId)
      .single();

    const genreData = (track?.genres as unknown) as { name: string } | null;
    const genreName = genreData?.name || "electronic";

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

    for (const addon of trackAddons) {
      const addonServiceData = (addon.addon_service as unknown) as { name: string; name_ru: string } | null;
      const addonName = addonServiceData?.name;
      console.log(`Processing addon: ${addonName} for track ${trackId}`);

      // Update status to processing
      await supabaseAdmin
        .from("track_addons")
        .update({ status: "processing", updated_at: new Date().toISOString() })
        .eq("id", addon.id);

      let functionName: string | null = null;
      let requestBody: Record<string, unknown> = {
        track_id: trackId,
        track_title: trackTitle,
        genre: genreName,
      };
      
      if (addonName === "large_cover") {
        functionName = "generate-hd-cover";
        requestBody.original_cover_url = coverUrl;
      } else if (addonName === "short_video") {
        functionName = "generate-short-video";
        requestBody.cover_url = coverUrl;
        // For Suno music video generation, we need the task_id and audio_id
        if (sunoTaskId) {
          requestBody.suno_task_id = sunoTaskId;
        }
        if (sunoAudioId) {
          requestBody.suno_audio_id = sunoAudioId;
        }
      } else if (addonName === "ringtone") {
        functionName = "generate-ringtone";
        requestBody.audio_url = audioUrl;
      }

      if (functionName) {
        try {
          // Call the edge function directly using fetch
          const response = await fetch(`${SUPABASE_URL}/functions/v1/${functionName}`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "Authorization": `Bearer ${SUPABASE_SERVICE_KEY}`,
            },
            body: JSON.stringify(requestBody),
          });

          const result = await response.json();
          console.log(`${functionName} result for track ${trackId}:`, result);

          if (!result.success) {
            // Mark as failed
            await supabaseAdmin
              .from("track_addons")
              .update({ 
                status: "failed", 
                updated_at: new Date().toISOString() 
              })
              .eq("id", addon.id);
          }
          // Note: successful result_url update is handled by the edge function itself
        } catch (fnError) {
          console.error(`Error calling ${functionName}:`, fnError);
          await supabaseAdmin
            .from("track_addons")
            .update({ 
              status: "failed", 
              updated_at: new Date().toISOString() 
            })
            .eq("id", addon.id);
        }
      } else {
        console.log(`Unknown addon type: ${addonName}, marking as failed`);
        await supabaseAdmin
          .from("track_addons")
          .update({ 
            status: "failed", 
            updated_at: new Date().toISOString() 
          })
          .eq("id", addon.id);
      }
    }
  } catch (error) {
    console.error("Error processing track addons:", error);
  }
}

// ─── Trigger Suno Cover Generation ──────────────────────────────────
// After music is generated, request personalized cover art via Suno Cover API
// Docs: https://docs.sunoapi.org/suno-api/cover-suno
async function triggerCoverGeneration(
  supabaseAdmin: SupabaseClient,
  musicTaskId: string,
  matchedTrackIds: string[]
) {
  try {
    const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
    const SUNO_API_BASE = "https://apibox.erweima.ai";
    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";

    if (!SUNO_API_KEY) {
      console.error("SUNO_API_KEY not set, skipping cover generation");
      return;
    }

    // Build cover callback URL
    const coverCallbackUrl = callbackSecret
      ? `${baseUrl}/functions/v1/suno-cover-callback?secret=${encodeURIComponent(callbackSecret)}`
      : `${baseUrl}/functions/v1/suno-cover-callback`;

    console.log(`Triggering Suno cover generation for music task ${musicTaskId}`);
    console.log(`Cover callback URL: ${coverCallbackUrl}`);

    // Call Suno Cover API
    // Try primary path first, then fallback
    const paths = [
      "/api/v1/suno/cover/generate",
      "/api/v1/cover/generate",
    ];

    let coverResponse = null;
    let coverData = null;

    for (const path of paths) {
      try {
        const url = `${SUNO_API_BASE}${path}`;
        console.log(`Trying cover API: ${url}`);

        coverResponse = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${SUNO_API_KEY}`,
          },
          body: JSON.stringify({
            taskId: musicTaskId,
            callBackUrl: coverCallbackUrl,
          }),
        });

        coverData = await coverResponse.json();
        console.log(`Cover API response (${path}):`, JSON.stringify(coverData));

        // If not a 404 (wrong path), we found the right endpoint
        if (coverResponse.status !== 404) break;
      } catch (fetchErr) {
        console.error(`Cover API fetch error (${path}):`, fetchErr);
      }
    }

    if (!coverData || (coverData.code !== 200 && coverData.code !== 400)) {
      console.error(`Cover API failed: ${JSON.stringify(coverData)}`);
      return;
    }

    // code 400 = cover already generated for this task (returns existing taskId)
    const coverTaskId = coverData.data?.taskId;
    if (!coverTaskId) {
      console.error("No coverTaskId in response");
      return;
    }

    console.log(`Cover generation started, cover_task_id: ${coverTaskId}`);

    // Store cover_task_id in matched tracks for callback matching
    for (const trackId of matchedTrackIds) {
      const { data: track } = await supabaseAdmin
        .from("tracks")
        .select("description")
        .eq("id", trackId)
        .single();

      if (track) {
        // Only add if not already present
        if (!track.description?.includes(`[cover_task_id: ${coverTaskId}]`)) {
          const newDesc = track.description
            ? `${track.description}\n\n[cover_task_id: ${coverTaskId}]`
            : `[cover_task_id: ${coverTaskId}]`;

          await supabaseAdmin
            .from("tracks")
            .update({ description: newDesc })
            .eq("id", trackId);

          console.log(`Stored cover_task_id ${coverTaskId} in track ${trackId}`);
        }
      }
    }
  } catch (err) {
    console.error("Error triggering cover generation:", err);
  }
}

// Human-readable error messages for Suno error codes
// Official Suno API error codes reference:
// 400 - Invalid Parameters
// 401 - Unauthorized
// 403 - Forbidden (moderation/copyright)
// 404 - Not Found
// 405 - Rate Limited (API frequency)
// 413 - Content Too Large (prompt/lyrics too long)
// 429 - Insufficient Credits
// 455 - Maintenance
// 500/503 - Server errors
function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  // First, check for specific error message patterns (more accurate than just code)
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();
    
    // Copyright/content matching detection
    if (lowerMsg.includes("matches existing work") || 
        lowerMsg.includes("existing work of art") ||
        lowerMsg.includes("copyright") ||
        lowerMsg.includes("protected content")) {
      return {
        short: "Контент защищён авторским правом",
        full: "Загруженный аудиофайл или текст распознан как существующее произведение. Система защиты авторских прав Suno заблокировала генерацию. Попробуйте использовать оригинальный контент."
      };
    }
    
    // Moderation/sensitive content
    if (lowerMsg.includes("moderation") || 
        lowerMsg.includes("sensitive") || 
        lowerMsg.includes("inappropriate") ||
        lowerMsg.includes("prohibited")) {
      return {
        short: "Контент не прошёл модерацию",
        full: "Текст или описание содержит запрещённые слова или фразы. Измените содержимое и попробуйте снова."
      };
    }
    
    // Audio fetch issues
    if (lowerMsg.includes("fetch") && lowerMsg.includes("audio")) {
      return {
        short: "Не удалось получить аудиофайл",
        full: "Сервер не смог загрузить ваш аудиофайл. Проверьте, что файл доступен и попробуйте снова."
      };
    }
    
    // Content too long (can come in message too)
    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Сократите текст и попробуйте снова."
      };
    }
    
    // Credits issues
    if (lowerMsg.includes("credit") || lowerMsg.includes("balance") || lowerMsg.includes("insufficient")) {
      return {
        short: "Недостаточно кредитов Suno",
        full: "На аккаунте Suno недостаточно кредитов для генерации. Обратитесь в поддержку."
      };
    }
  }

  // Fallback to code-based messages
  const errorMessages: Record<number, { short: string; full: string }> = {
    400: {
      short: "Неверные параметры запроса",
      full: "Параметры генерации некорректны. Проверьте введённые данные и попробуйте снова."
    },
    401: {
      short: "Ошибка авторизации",
      full: "Проблема с авторизацией в сервисе Suno. Обратитесь в поддержку."
    },
    403: {
      short: "Контент заблокирован модерацией",
      full: "Ваш запрос содержит запрещённый контент или нарушает правила использования Suno. Измените текст или описание."
    },
    404: {
      short: "Ресурс не найден",
      full: "Запрашиваемый ресурс не найден. Попробуйте ещё раз."
    },
    405: {
      short: "Превышена частота запросов",
      full: "Слишком много запросов к API. Подождите несколько минут и попробуйте снова."
    },
    413: {
      short: "Превышен лимит символов",
      full: "Описание, стиль или текст песни слишком длинные для обработки. Сократите текст (макс. ~3000 символов для lyrics, ~200 для style) и попробуйте снова."
    },
    429: {
      short: "Недостаточно кредитов",
      full: "На аккаунте Suno недостаточно кредитов для генерации. Обратитесь в поддержку."
    },
    455: {
      short: "Сервис на обслуживании",
      full: "Сервис Suno проходит техническое обслуживание. Попробуйте позже."
    },
    500: {
      short: "Внутренняя ошибка сервера",
      full: "Произошла внутренняя ошибка на сервере Suno. Попробуйте позже."
    },
    503: {
      short: "Сервис временно недоступен",
      full: "Сервис Suno временно перегружен или на обслуживании. Попробуйте позже."
    }
  };
  
  if (errorMessages[code]) {
    return errorMessages[code];
  }
  
  return {
    short: `Ошибка генерации (код ${code})`,
    full: originalMessage || `Произошла ошибка при генерации. Код ошибки: ${code}. Попробуйте позже или обратитесь в поддержку.`
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Verify callback authenticity using secret token
    const callbackSecret = Deno.env.get("SUNO_CALLBACK_SECRET");
    if (callbackSecret) {
      // Check for secret in header or query parameter
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
      console.log("Callback secret verified successfully");
    } else {
      console.warn("SUNO_CALLBACK_SECRET not configured - callback verification skipped");
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const callbackData = await req.json();
    console.log("Received Suno callback:", JSON.stringify(callbackData));

    // Handle the nested data structure from Suno API
    // The structure is: { code: 200, data: { callbackType: "complete", data: [...tracks], task_id: "..." }, msg: "..." }
    const tracks = callbackData?.data?.data || callbackData?.data || [];
    const taskId = callbackData?.data?.task_id;
    const callbackType = callbackData?.data?.callbackType;
    const responseCode = callbackData?.code;
    const errorMessage = callbackData?.msg;
    
    console.log(`Callback type: ${callbackType}, Task ID: ${taskId}, Code: ${responseCode}, Tracks count: ${tracks.length}`);

    // Handle failed callbacks - check for error codes OR explicit failure types
    // Suno may return code 413 with callbackType "complete" when audio can't be fetched
    const isError = responseCode !== 200 || 
                    callbackType === "fail" || 
                    callbackType === "error" || 
                    callbackType === "failed";
    
    if (isError) {
      console.log(`Received error callback for task ${taskId} - code: ${responseCode}, type: ${callbackType}`);
      
      // Get human-readable error message
      const errorInfo = getSunoErrorMessage(responseCode || 500, errorMessage || callbackData?.data?.fail_reason);
      const failReason = errorInfo.short;
      
      // Find tracks that match this task_id first, then fall back to recent pending tracks
      let tracksToFail: { id: string; user_id: string }[] = [];
      
      // Try to find tracks by taskId in description metadata
      if (taskId) {
        const { data: taskTracks } = await supabaseAdmin
          .from("tracks")
          .select("id, user_id, description")
          .in("status", ["processing", "pending"])
          .ilike("description", `%${taskId}%`)
          .limit(2);
        
        if (taskTracks && taskTracks.length > 0) {
          tracksToFail = taskTracks;
          console.log(`Found ${taskTracks.length} tracks matching task_id ${taskId}`);
        }
      }
      
      // Fall back to recent pending tracks if no task match
      if (tracksToFail.length === 0) {
        const { data: pendingTracks } = await supabaseAdmin
          .from("tracks")
          .select("id, user_id")
          .in("status", ["processing", "pending"])
          .order("created_at", { ascending: false })
          .limit(5);
      
        if (pendingTracks && pendingTracks.length > 0) {
          tracksToFail = pendingTracks;
        }
      }
      
      if (tracksToFail.length > 0) {
        for (const track of tracksToFail) {
          await supabaseAdmin
            .from("tracks")
            .update({
              status: "failed",
              error_message: failReason,
            })
            .eq("id", track.id);
          
          // Get generation log to find cost
          const { data: genLog } = await supabaseAdmin
            .from("generation_logs")
            .select("cost_rub")
            .eq("track_id", track.id)
            .single();
          
          // Refund ₽ to user
          if (genLog && genLog.cost_rub > 0) {
            const { data: profile } = await supabaseAdmin
              .from("profiles")
              .select("balance")
              .eq("user_id", track.user_id)
              .single();
            
            if (profile) {
              const newBalance = (profile.balance || 0) + genLog.cost_rub;
              await supabaseAdmin
                .from("profiles")
                .update({ balance: newBalance })
                .eq("user_id", track.user_id);
              
              // Log refund transaction
              await supabaseAdmin.from("balance_transactions").insert({
                user_id: track.user_id,
                amount: genLog.cost_rub,
                balance_after: newBalance,
                type: "refund",
                description: `Возврат за генерацию: ${failReason}`,
                reference_id: track.id,
                reference_type: "track",
              });
              
              console.log(`Refunded ${genLog.cost_rub} ₽ to user ${track.user_id}`);
              
              // Create notification for refund with error explanation
              await supabaseAdmin
                .from("notifications")
                .insert({
                  user_id: track.user_id,
                  type: "refund",
                  title: `Ошибка: ${failReason}`,
                  message: `${errorInfo.full}\n\nВам возвращено ${genLog.cost_rub} ₽`,
                  target_type: "track",
                  target_id: track.id,
                });
            }
          }
          
          // Update generation log status to failed
          await supabaseAdmin
            .from("generation_logs")
            .update({ status: "failed" })
            .eq("track_id", track.id);
        }
        console.log(`Marked ${tracksToFail.length} tracks as failed with refunds`);
      }
      
      return new Response(
        JSON.stringify({ received: true, message: "Failure callback processed with refunds" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!Array.isArray(tracks) || tracks.length === 0) {
      console.log("No tracks in callback data");
      return new Response(
        JSON.stringify({ received: true, message: "No tracks to process" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Process "complete" (all tracks ready) and "first" (first track ready) callbacks
    // Skip "text" callbacks (only lyrics generated, no audio yet)
    if (callbackType !== "complete" && callbackType !== "first") {
      console.log(`Skipping callback type: ${callbackType} (waiting for audio)`);
      return new Response(
        JSON.stringify({ received: true, message: `Callback type ${callbackType} acknowledged` }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const isPartialCallback = callbackType === "first";
    if (isPartialCallback) {
      console.log(`Processing partial callback (first) — will only update tracks that have audio_url`);
    }

    // CRITICAL: First, find tracks that match this specific task_id
    // This prevents cross-user track mixing when multiple generations are pending
    let matchedTracks: Array<{
      id: string;
      title: string | null;
      description: string | null;
      lyrics: string | null;
      user_id: string;
      status: string;
    }> = [];

    if (taskId) {
      const { data: taskTracks, error: taskFindError } = await supabaseAdmin
        .from("tracks")
        .select("id, title, description, lyrics, user_id, status")
        .in("status", ["processing", "pending"])
        .ilike("description", `%[task_id: ${taskId}]%`)
        .order("created_at", { ascending: true })
        .limit(2);

      if (taskFindError) {
        console.error("Error finding tracks by task_id:", taskFindError);
      } else if (taskTracks && taskTracks.length > 0) {
        matchedTracks = taskTracks;
        console.log(`Found ${taskTracks.length} tracks matching task_id ${taskId}`);
      }
    }

    // If no task_id match, log a warning but DO NOT fall back to random pending tracks
    // This is critical to prevent cross-user track mixing
    if (matchedTracks.length === 0) {
      console.warn(`No tracks found matching task_id ${taskId}. Callback will be ignored to prevent cross-user mixing.`);
      console.warn(`Callback data had ${tracks.length} audio tracks, but no matching DB records.`);
      return new Response(
        JSON.stringify({ 
          received: true, 
          warning: "No matching tracks found for task_id", 
          task_id: taskId 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let updatedCount = 0;

    // Create a copy of matched tracks for safe iteration (avoid mutation issues)
    const tracksToProcess = [...matchedTracks];
    // Track which indices have been processed
    const processedIndices = new Set<number>();

    // Suno returns 2 versions per generation request
    // Match them to our v1/v2 track pairs by order (first Suno result -> v1, second -> v2)
    for (let i = 0; i < tracks.length; i++) {
      const track = tracks[i];
      const { 
        id: sunoAudioId,
        audio_url, 
        source_audio_url,
        stream_audio_url,
        image_url,
        source_image_url,
        duration, 
        title: sunoTitle,
      } = track;

      const audioUrl = audio_url || source_audio_url || stream_audio_url;
      const coverUrl = image_url || source_image_url;
      
      if (!audioUrl) {
        console.log("Track has no audio URL, skipping");
        continue;
      }

      // Match by index: first Suno result -> first matched track (v1), second -> second (v2)
      // Use the original array copy, not the mutated one
      const trackToUpdate = tracksToProcess[i];
      
      // Safety check: ensure we're updating the right user's track
      if (!trackToUpdate) {
        console.log(`No matched track at index ${i} for Suno result: ${sunoTitle}`);
        continue;
      }
      
      // Skip if already processed (shouldn't happen, but be safe)
      if (processedIndices.has(i)) {
        console.log(`Track at index ${i} already processed, skipping`);
        continue;
      }
      
      processedIndices.add(i);
      console.log(`Updating track ${trackToUpdate.id} (${trackToUpdate.title}) with audio: ${audioUrl}`);
      
      // Copy files to Supabase Storage for permanent storage
      let finalAudioUrl = audioUrl;
      let finalCoverUrl = coverUrl;
      
      // Copy audio file to Storage
      try {
        const audioFileName = `${trackToUpdate.id}.mp3`;
        const storedAudioUrl = await copyFileToStorage(
          supabaseAdmin,
          audioUrl,
          "tracks",
          `audio/${audioFileName}`
        );
        if (storedAudioUrl) {
          finalAudioUrl = storedAudioUrl;
          console.log(`Audio copied to storage: ${finalAudioUrl}`);
        } else {
          console.log(`Failed to copy audio, using original URL`);
        }
      } catch (audioErr) {
        console.error(`Error copying audio:`, audioErr);
      }
      
      // Copy cover image to Storage
      if (coverUrl) {
        try {
          const coverFileName = `${trackToUpdate.id}.jpg`;
          const storedCoverUrl = await copyFileToStorage(
            supabaseAdmin,
            coverUrl,
            "tracks",
            `covers/${coverFileName}`
          );
          if (storedCoverUrl) {
            finalCoverUrl = storedCoverUrl;
            console.log(`Cover copied to storage: ${finalCoverUrl}`);
          } else {
            console.log(`Failed to copy cover, using original URL`);
          }
        } catch (coverErr) {
          console.error(`Error copying cover:`, coverErr);
        }
      }
      
      const { error: updateError } = await supabaseAdmin
        .from("tracks")
        .update({
          audio_url: finalAudioUrl,
          cover_url: finalCoverUrl || null,
          duration: duration ? Math.round(duration) : null,
          status: "completed",
          // Store Suno audio ID for persona creation
          suno_audio_id: sunoAudioId || null,
          // Store suno_task_id in description for reference (append to existing)
          description: trackToUpdate.description 
            ? `${trackToUpdate.description}\n\n[task_id: ${taskId}]`
            : `[task_id: ${taskId}]`,
        })
        .eq("id", trackToUpdate.id);

      if (updateError) {
        console.error("Error updating track:", updateError);
      } else {
        console.log(`Track ${trackToUpdate.id} updated successfully with Storage URLs`);
        updatedCount++;

        // Update generation log status
        await supabaseAdmin
          .from("generation_logs")
          .update({ status: "completed" })
          .eq("track_id", trackToUpdate.id);


        // Process addon services for this track (pass taskId and audioId for Suno video generation)
        await processTrackAddons(supabaseAdmin, trackToUpdate.id, trackToUpdate.title || "Untitled", finalCoverUrl, finalAudioUrl, taskId, sunoAudioId);

        // AI Classification - run in background to not block response
        // Extract style from track description (before task_id was appended)
        const originalDescription = trackToUpdate.description?.replace(/\n\n\[task_id:.*\]$/, "") || null;
        const trackLyrics = trackToUpdate.lyrics || null;
        
        runInBackground(
          `classifyTrack-${trackToUpdate.id}`,
          classifyTrackWithAI(supabaseAdmin, trackToUpdate.id, originalDescription, trackLyrics)
        );
      }
    }

    // ─── Trigger Suno Cover Generation (background) ────────────────
    // After all music tracks are updated, request personalized cover art
    // This runs in background so we don't delay the callback response
    // Only trigger on "complete" callback (not "first") to avoid premature cover generation
    if (updatedCount > 0 && taskId && !isPartialCallback) {
      const trackIdsForCover = tracksToProcess
        .filter(t => processedIndices.has(tracksToProcess.indexOf(t)))
        .map(t => t.id);

      if (trackIdsForCover.length > 0) {
        runInBackground(
          `coverGeneration-${taskId}`,
          triggerCoverGeneration(supabaseAdmin, taskId, trackIdsForCover)
        );
      }
    }

    return new Response(
      JSON.stringify({ success: true, updated: updatedCount }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in suno-callback:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
