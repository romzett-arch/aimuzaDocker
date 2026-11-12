import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./constants.ts";
import { validateAuth, AuthError } from "./auth.ts";
import { copyWavToStorage, convertMp3ToWavViaFfmpeg } from "./utils.ts";

/**
 * Переписывает публичный storage-URL на внутренний origin SUPABASE_URL,
 * чтобы ffmpeg-api мог скачать мастер-файл без внешнего выхода
 * (паттерн toInternalFetchUrl из generate-release-package).
 */
function toInternalStorageUrl(rawUrl: string, storageOrigin: string): string {
  const origin = (storageOrigin || "").replace(/\/$/, "");
  if (!origin) return rawUrl;

  try {
    const target = new URL(rawUrl);
    if (target.pathname.startsWith("/storage/v1/object/public/")) {
      return `${origin}${target.pathname}${target.search}`;
    }
  } catch {
    return rawUrl;
  }

  return rawUrl;
}

async function persistAddonState(
  supabase: ReturnType<typeof createClient>,
  params: {
    trackId: string;
    userId: string;
    addonServiceId: string;
    status: string;
    resultUrl: string;
  },
): Promise<string> {
  const { trackId, userId, addonServiceId, status, resultUrl } = params;
  let wavTaskId: string | null=null;
  try {wavTaskId=JSON.parse(resultUrl)?.wav_task_id||null;} catch {}
  if(status==='completed') {
    const {data:existing}=await supabase.from('track_addons').select('id').eq('track_id',trackId).eq('addon_service_id',addonServiceId).single();
    if(!existing) throw new Error('WAV reservation missing');
    const {data:done,error}=await supabase.rpc('security_complete_wav',{p_addon_id:existing.id,p_result_url:resultUrl});
    if(error||!done) throw new Error('WAV settlement failed');
    return existing.id;
  }

  const { data: existingAddon, error: existingAddonError } = await supabase
    .from("track_addons")
    .select("id")
    .eq("track_id", trackId)
    .eq("addon_service_id", addonServiceId)
    .maybeSingle();

  if (existingAddonError) {
    throw new Error(`track_addons_lookup_failed: ${existingAddonError.message}`);
  }

  if (existingAddon?.id) {
    const { error: updateError } = await supabase
      .from("track_addons")
      .update({
        user_id: userId,
        wav_task_id: wavTaskId,
        status,
        result_url: resultUrl,
        updated_at: new Date().toISOString(),
      })
      .eq("id", existingAddon.id);

    if (updateError) {
      throw new Error(`track_addons_update_failed: ${updateError.message}`);
    }

    return existingAddon.id;
  }

  const { data: insertedAddon, error: insertError } = await supabase
    .from("track_addons")
    .insert({
      track_id: trackId,
      user_id: userId,
      wav_task_id: wavTaskId,
      addon_service_id: addonServiceId,
      status,
      result_url: resultUrl,
      updated_at: new Date().toISOString(),
    })
    .select("id")
    .single();

  if (insertError || !insertedAddon?.id) {
    throw new Error(`track_addons_insert_failed: ${insertError?.message || "missing_inserted_id"}`);
  }

  return insertedAddon.id;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  let reservedAddonId: string | null = null;

  try {
    let userId: string | null;
    let isInternalCall: boolean;
    try {
      const auth = await validateAuth(req, supabaseUrl, supabaseServiceKey, supabaseAnonKey);
      userId = auth.userId;
      isInternalCall = auth.isInternalCall;
    } catch (e) {
      if (e instanceof AuthError) {
        return new Response(
          JSON.stringify({ error: e.message }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      throw e;
    }

    const body = await req.json();
    const { track_id } = body;

    console.log("Convert to WAV request:", { track_id, userId, isInternalCall });

    const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
    const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");
    const ffmpegPublicUrl = Deno.env.get("FFMPEG_PUBLIC_URL");
    if (!ffmpegApiUrl || !ffmpegApiSecret) {
      throw new Error("FFmpeg WAV conversion unavailable");
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select("id, user_id, title, description, audio_url, master_audio_url, normalized_audio_url, performer_name, label_name")
      .eq("id", track_id)
      .single();

    if (trackError || !track) {
      throw new Error("Track not found");
    }

    if (!isInternalCall && track.user_id !== userId) {
      return new Response(
        JSON.stringify({ error: "Access denied - not your track" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: addonService } = await supabase
      .from("addon_services")
      .select("id, price_rub")
      .eq("name", "convert_wav")
      .single();

    if (!addonService) {
      throw new Error("WAV conversion service not found");
    }

    const markAddonFailed = async (addonId?: string) => {
      if (!addonId) return;
      await supabase.rpc('security_fail_wav',{p_addon_id:addonId});
    };

    const finalizeWavAddon = async (sourceUrl: string, addonId?: string): Promise<string> => {
      const { data: profile } = await supabase
        .from("profiles")
        .select("username, display_name, short_id")
        .eq("user_id", track.user_id)
        .single();
      const artistName = track.performer_name || profile?.display_name || profile?.username || "AIMuza Artist";
      const publisherName = track.label_name || "AIMuza";
      const cabinetId = profile?.short_id || track.user_id;

      const finalWavUrl = await convertMp3ToWavViaFfmpeg(
        sourceUrl,
        track_id,
        track.title,
        artistName,
        publisherName,
        cabinetId,
        ffmpegApiUrl,
        ffmpegApiSecret,
        ffmpegPublicUrl ?? undefined,
      );

      if (!finalWavUrl) {
        await markAddonFailed(addonId);
        throw new Error("FFmpeg WAV conversion failed");
      }

      const stableWavUrl = await copyWavToStorage(supabase, finalWavUrl, track_id, ffmpegApiUrl);
      if (!stableWavUrl) {
        await markAddonFailed(addonId);
        throw new Error("Failed to persist WAV to storage");
      }

      await persistAddonState(supabase, {
        trackId: track_id,
        userId: track.user_id,
        addonServiceId: addonService.id,
        status: "completed",
        resultUrl: stableWavUrl,
      });

      return stableWavUrl;
    };

    // Проверяем существующий addon — не списываем повторно если уже processing/completed
    const { data: existingAddon } = await supabase
      .from("track_addons")
      .select("id, status, result_url")
      .eq("track_id", track_id)
      .eq("addon_service_id", addonService.id)
      .maybeSingle();

    if (existingAddon?.status === "completed" && existingAddon.result_url) {
      console.log("WAV addon already completed:", existingAddon.result_url);
      return new Response(
        JSON.stringify({ success: true, wav_url: existingAddon.result_url, message: "WAV already available" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Легаси-строки старых асинхронных конвертаций: их довершает wav-callback
    if (["pending","processing","callback_processing"].includes(existingAddon?.status)) {
      console.log("WAV conversion already in progress");
      return new Response(
        JSON.stringify({ success: true, message: "WAV conversion already in progress" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Мастер-источник конвертации — тот же, что отдаётся в MP3 (download-track, релиз-пакет)
    const masterUrl: string | null = track.master_audio_url || track.normalized_audio_url || track.audio_url;
    if (!masterUrl) {
      throw new Error("У трека нет аудиофайла для конвертации в WAV");
    }

    const {data:reservation,error:reserveError}=await supabase.rpc('security_reserve_wav',{p_track_id:track_id,p_charge:!isInternalCall});
    if(reserveError) throw new Error('WAV reservation failed');
    if(!reservation?.started) return new Response(JSON.stringify({success:true,message:'WAV already reserved'}),{headers:{...corsHeaders,'Content-Type':'application/json'}});
    reservedAddonId=reservation.addon_id;

    const internalSourceUrl = toInternalStorageUrl(masterUrl, supabaseUrl);
    const finalWavUrl = await finalizeWavAddon(internalSourceUrl, reservedAddonId ?? undefined);

    return new Response(
      JSON.stringify({ success: true, wav_url: finalWavUrl, message: "WAV ready" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in convert-to-wav:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    if (reservedAddonId) {
      const refundClient=createClient(supabaseUrl,supabaseServiceKey);
      const {error:refundError}=await refundClient.rpc('security_fail_wav',{p_addon_id:reservedAddonId});
      if(refundError) console.error('WAV refund requires retry');
    }
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
