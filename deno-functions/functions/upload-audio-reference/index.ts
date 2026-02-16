import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SUNO_API_KEY = Deno.env.get("SUNO_API_KEY");
const SUNO_UPLOAD_BASE = "https://sunoapiorg.redpandaai.co";

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

      // First upload file to Supabase Storage to get a public URL
      const fileExt = file.name.split('.').pop() || 'mp3';
      const fileName = `${user.id}/${Date.now()}_${crypto.randomUUID()}.${fileExt}`;
      
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

      // Get public URL
      const { data: urlData } = supabaseClient.storage
        .from("audio-references")
        .getPublicUrl(fileName);

      const publicUrl = urlData?.publicUrl;
      
      if (!publicUrl) {
        return new Response(
          JSON.stringify({ error: "Не удалось получить URL файла" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      console.log(`File saved to storage: ${publicUrl}`);

      // Now upload to Suno using URL endpoint (much more memory efficient)
      const uploadResponse = await fetch(`${SUNO_UPLOAD_BASE}/api/file-url-upload`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${SUNO_API_KEY}`,
        },
        body: JSON.stringify({
          url: publicUrl,
        }),
      });

      const uploadData = await uploadResponse.json();
      console.log("Suno upload response:", JSON.stringify(uploadData));

      if (!uploadResponse.ok || uploadData.code !== 200) {
        console.error("Suno upload failed:", uploadData);
        return new Response(
          JSON.stringify({ error: uploadData.msg || "Ошибка загрузки файла в Suno" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const uploadUrl = uploadData.data?.url || uploadData.data;
      
      if (!uploadUrl) {
        console.error("No upload URL in response:", uploadData);
        return new Response(
          JSON.stringify({ error: "Не удалось получить URL от Suno" }),
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

    // Upload to Suno using URL endpoint
    const uploadResponse = await fetch(`${SUNO_UPLOAD_BASE}/api/file-url-upload`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUNO_API_KEY}`,
      },
      body: JSON.stringify({
        url: audioUrl,
      }),
    });

    const uploadData = await uploadResponse.json();
    console.log("Suno URL upload response:", JSON.stringify(uploadData));

    if (!uploadResponse.ok || uploadData.code !== 200) {
      console.error("Suno URL upload failed:", uploadData);
      return new Response(
        JSON.stringify({ error: uploadData.msg || "Ошибка загрузки по URL" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const uploadUrl = uploadData.data?.url || uploadData.data;

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
