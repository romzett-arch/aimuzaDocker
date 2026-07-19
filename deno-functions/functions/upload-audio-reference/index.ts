import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_UPLOAD_BASE = "https://sunoapiorg.redpandaai.co";

function inferAudioExtension(source: string, mimeType?: string): "mp3" | "wav" {
  const normalizedMimeType = mimeType?.toLowerCase();
  if (normalizedMimeType === "audio/wav" || normalizedMimeType === "audio/wave" || normalizedMimeType === "audio/x-wav") {
    return "wav";
  }
  if (normalizedMimeType === "audio/mpeg" || normalizedMimeType === "audio/mp3") {
    return "mp3";
  }

  try {
    const path = new URL(source).pathname;
    const extension = decodeURIComponent(path).match(/\.(mp3|wav|wave)$/i)?.[1]?.toLowerCase();
    return extension === "wav" || extension === "wave" ? "wav" : "mp3";
  } catch {
    const extension = source.split(/[?#]/)[0].match(/\.(mp3|wav|wave)$/i)?.[1]?.toLowerCase();
    return extension === "wav" || extension === "wave" ? "wav" : "mp3";
  }
}

function createSafeProviderFileName(source: string, mimeType?: string): string {
  const extension = inferAudioExtension(source, mimeType);
  const transliteration: Record<string, string> = {
    а: "a", б: "b", в: "v", г: "g", д: "d", е: "e", ё: "yo", ж: "zh", з: "z", и: "i", й: "y",
    к: "k", л: "l", м: "m", н: "n", о: "o", п: "p", р: "r", с: "s", т: "t", у: "u", ф: "f",
    х: "h", ц: "ts", ч: "ch", ш: "sh", щ: "sch", ъ: "", ы: "y", ь: "", э: "e", ю: "yu", я: "ya",
  };

  let sourceName = source;
  try {
    const pathParts = decodeURIComponent(new URL(source).pathname).split("/");
    sourceName = pathParts.at(-1) || source;
  } catch {
    sourceName = source.split(/[?#]/)[0].split(/[\\/]/).at(-1) || source;
  }

  const baseName = sourceName.replace(/\.(mp3|wav|wave)$/i, "");
  const transliterated = Array.from(baseName.toLowerCase())
    .map((character) => transliteration[character] ?? character)
    .join("")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 28)
    .replace(/-+$/g, "");
  const safeBaseName = transliterated || "audio-reference";
  const uniqueSuffix = crypto.randomUUID().slice(0, 6);

  return `${safeBaseName}-${uniqueSuffix}.${extension}`;
}

async function resolvePublicAudioUrl(audioUrl: string): Promise<{ fileUrl: string; fileName: string }> {
  let parsedUrl: URL;
  try {
    parsedUrl = new URL(audioUrl);
  } catch {
    throw new Error("Некорректная ссылка на аудио");
  }

  const host = parsedUrl.hostname.toLowerCase();
  const isYandexDisk = host === "disk.yandex.ru" || host.endsWith(".disk.yandex.ru") || host === "yadi.sk";

  if (!isYandexDisk) {
    return {
      fileUrl: audioUrl,
      fileName: createSafeProviderFileName(audioUrl),
    };
  }

  let publicKey = audioUrl;
  let resourcePath = "";
  const yandexParts = parsedUrl.pathname.split("/").filter(Boolean);
  if ((yandexParts[0] === "d" || yandexParts[0] === "i") && yandexParts[1]) {
    publicKey = `${parsedUrl.origin}/${yandexParts[0]}/${yandexParts[1]}`;
    const restPath = yandexParts.slice(2).join("/");
    if (restPath) {
      resourcePath = `/${decodeURIComponent(restPath)}`;
    }
  }

  const apiUrl = new URL("https://cloud-api.yandex.net/v1/disk/public/resources/download");
  apiUrl.searchParams.set("public_key", publicKey);
  if (resourcePath) {
    apiUrl.searchParams.set("path", resourcePath);
  }

  console.log(`Resolving Yandex Disk URL: publicKey=${publicKey}, path=${resourcePath || "/"}`);
  const response = await fetch(apiUrl);

  if (!response.ok) {
    console.error("Yandex Disk resolve failed:", response.status, await response.text());
    throw new Error("Не удалось получить прямую ссылку на файл Яндекс.Диска. Проверьте, что доступ открыт по ссылке.");
  }

  const data = await response.json();
  if (!data?.href) {
    console.error("Yandex Disk resolve returned no href:", data);
    throw new Error("Яндекс.Диск не вернул прямую ссылку на аудиофайл");
  }

  return {
    fileUrl: data.href,
    fileName: createSafeProviderFileName(String(data.name || parsedUrl.pathname)),
  };
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
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const supabaseAuth = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: userError } = await supabaseAuth.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const contentType = req.headers.get("content-type") || "";
    
    // Handle multipart form data (file upload)
    if (contentType.includes("multipart/form-data")) {
      const formData = await req.formData();
      const file = formData.get("file") as File;
      
      if (!file) {
        return new Response(
          JSON.stringify({ error: "No file provided" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Check file size (max 25MB for full tracks)
      const maxSize = 25 * 1024 * 1024;
      if (file.size > maxSize) {
        return new Response(
          JSON.stringify({ error: "Файл слишком большой. Максимум 25MB" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Check file type
      const allowedTypes = ["audio/mpeg", "audio/mp3", "audio/wav", "audio/wave", "audio/x-wav"];
      if (!allowedTypes.includes(file.type)) {
        return new Response(
          JSON.stringify({ error: "Неподдерживаемый формат. Используйте MP3 или WAV" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      console.log(`Uploading audio file: ${file.name}, size: ${file.size}, type: ${file.type}`);

      const fileExt = inferAudioExtension(file.name, file.type);
      const fileName = `${user.id}/${Date.now()}_${crypto.randomUUID()}.${fileExt}`;
      const providerFileName = createSafeProviderFileName(file.name, file.type);
      const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
      const isLocalhost = BASE_URL.includes("localhost") || BASE_URL.includes("127.0.0.1");
      let uploadData: any;

      if (isLocalhost) {
        const arrayBuffer = await file.arrayBuffer();
        const { error: uploadError } = await supabaseClient.storage
          .from("audio-references")
          .upload(fileName, arrayBuffer, {
            contentType: file.type,
            upsert: false,
          });

        if (uploadError) {
          console.error("Storage upload error:", uploadError);
          return new Response(
            JSON.stringify({ error: "Ошибка сохранения файла" }),
            { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        const publicUrl = `${BASE_URL}/storage/v1/object/public/audio-references/${fileName}`;
        console.log(`File saved to storage: ${publicUrl}`);

        // Localhost: Docker cannot upload files to external servers via HTTP/2.
        // file-url-upload needs a public URL, but http://localhost is not accessible externally.
        // Return the Storage URL directly — frontend will show a dev-mode warning.
        console.warn(`[localhost] Returning Storage URL directly (Suno CDN upload skipped): ${publicUrl}`);
        return new Response(
          JSON.stringify({
            success: true,
            uploadUrl: publicUrl,
            fileName: file.name,
            message: "Файл загружен в хранилище",
            localhostMode: true,
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } else {
        // Production: forward the stream directly instead of saving it and making
        // the provider download the same file again from AIMUZA storage.
        console.log(`Uploading audio stream to Suno as: ${providerFileName}`);
        const providerFormData = new FormData();
        providerFormData.append("file", file, providerFileName);
        providerFormData.append("uploadPath", `audio-references/${user.id}`);
        providerFormData.append("fileName", providerFileName);

        const uploadResponse = await fetch(`${SUNO_UPLOAD_BASE}/api/file-stream-upload`, {
          method: "POST",
          headers: { "Authorization": `Bearer ${SUNO_API_KEY}` },
          body: providerFormData,
        });

        try {
          uploadData = await uploadResponse.json();
        } catch {
          const text = await uploadResponse.text();
          console.error("Suno non-JSON response:", uploadResponse.status, text);
          return new Response(
            JSON.stringify({ error: "AIMUZA вернула некорректный ответ" }),
            { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        if (!uploadResponse.ok || (uploadData.code && uploadData.code !== 200)) {
          console.error("Suno upload failed:", uploadData);
          return new Response(
            JSON.stringify({ error: (uploadData.msg || "Ошибка загрузки файла в AIMUZA").replace(/suno/gi, "AIMUZA") }),
            { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
      }

      console.log("Suno upload response:", JSON.stringify(uploadData));

      if (uploadData.code && uploadData.code !== 200) {
        console.error("Suno upload failed:", uploadData);
        return new Response(
          JSON.stringify({ error: (uploadData.msg || "Ошибка загрузки файла в AIMUZA").replace(/suno/gi, "AIMUZA") }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const uploadUrl = uploadData.data?.downloadUrl || uploadData.data?.url || uploadData.data;
      
      if (!uploadUrl) {
        console.error("No upload URL in response:", uploadData);
        return new Response(
          JSON.stringify({ error: "Не удалось получить URL от AIMUZA" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      console.log(`File uploaded to Suno successfully: ${uploadUrl}`);

      return new Response(
        JSON.stringify({ 
          success: true, 
          uploadUrl,
          fileName: file.name,
          message: "Аудио загружено" 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    // Handle JSON body (URL upload)
    const { audioUrl } = await req.json();
    
    if (!audioUrl) {
      return new Response(
        JSON.stringify({ error: "No audio URL provided" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`Uploading audio from URL: ${audioUrl}`);

    let resolvedAudio: { fileUrl: string; fileName: string };
    try {
      resolvedAudio = await resolvePublicAudioUrl(audioUrl);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Не удалось обработать ссылку на аудио";
      return new Response(
        JSON.stringify({ error: message }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Upload to Suno using a direct audio URL. uploadPath must be a storage path,
    // not the source URL, otherwise Redpanda creates an invalid tempfile path.
    const requestBody = {
      fileUrl: resolvedAudio.fileUrl,
      uploadPath: `audio-references/${user.id}`,
      fileName: resolvedAudio.fileName,
    };
    console.log("Suno URL upload request:", JSON.stringify(requestBody));

    const uploadResponse = await fetch(`${SUNO_UPLOAD_BASE}/api/file-url-upload`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify(requestBody),
    });

    const uploadData = await uploadResponse.json();
    console.log("Suno URL upload response:", JSON.stringify(uploadData));

    if (!uploadResponse.ok || (uploadData.code && uploadData.code !== 200)) {
      console.error("Suno URL upload failed:", uploadData);
      return new Response(
        JSON.stringify({ error: uploadData.msg || "Ошибка загрузки по URL" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const uploadUrl = uploadData.data?.downloadUrl || uploadData.data?.url || uploadData.data;

    return new Response(
      JSON.stringify({ 
        success: true, 
        uploadUrl,
        message: "Аудио загружено" 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in upload-audio-reference:", error);
    return new Response(
      JSON.stringify({ error: "Произошла ошибка при загрузке" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
