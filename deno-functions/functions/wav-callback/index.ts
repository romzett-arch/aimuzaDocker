import { safeMediaFetch } from "../_shared/safe-media-fetch.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callbackAuthorized } from "../_shared/callback-auth.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

function getTaskId(payload: Record<string, any>): string | null {
  return payload?.data?.task_id
    ?? payload?.data?.taskId
    ?? payload?.task_id
    ?? payload?.taskId
    ?? null;
}

function getWavUrl(payload: Record<string, any>): string | null {
  return payload?.data?.audio_wav_url
    ?? payload?.data?.audioWavUrl
    ?? payload?.data?.response?.audio_wav_url
    ?? payload?.data?.response?.audioWavUrl
    ?? null;
}

function toReachableAudioUrl(url: string, ffmpegApiUrl?: string): string {
  if (!ffmpegApiUrl) return url;

  try {
    const target = new URL(url);
    if (target.pathname.startsWith("/api/ffmpeg/")) {
      const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "").replace(/\/$/, "");
      return `${baseUrl}${target.pathname.replace(/^\/api\/ffmpeg/, "")}${target.search}`;
    }
  } catch {
    return url;
  }

  return url;
}

async function isUsableAudioUrl(url: string, ffmpegApiUrl?: string): Promise<boolean> {
  try {
    const response = await safeMediaFetch(toReachableAudioUrl(url, ffmpegApiUrl), { method: "HEAD" });
    if (!response.ok) {
      console.warn(`[wav-cb] HEAD check failed for ${url}: ${response.status}`);
      return false;
    }

    const contentType = response.headers.get("content-type")?.toLowerCase() || "";
    if (contentType.includes("text/html") || contentType.includes("application/json")) {
      console.warn(`[wav-cb] Unexpected content-type for ${url}: ${contentType}`);
      return false;
    }

    const contentLength = Number(response.headers.get("content-length") || "0");
    if (contentLength > 0 && contentLength < 1000) {
      console.warn(`[wav-cb] Suspiciously small file for ${url}: ${contentLength} bytes`);
      return false;
    }

    return true;
  } catch (error) {
    console.warn(`[wav-cb] HEAD check error for ${url}:`, error);
    return false;
  }
}

async function processWavViaFfmpeg(
  rawWavUrl: string,
  trackTitle: string,
  artistName: string,
  publisherName: string,
  cabinetId: string,
  ffmpegApiUrl: string,
  ffmpegApiSecret: string,
  ffmpegPublicUrl?: string,
): Promise<string | null> {
  try {
    const baseUrl = ffmpegApiUrl.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "");
    console.log(`[wav-cb] Processing WAV via ffmpeg-api: ${baseUrl}/process-wav`);

    const resp = await fetch(`${baseUrl}/process-wav`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ffmpegApiSecret,
      },
      body: JSON.stringify({
        audio_url: rawWavUrl,
        target_lufs: -10,
        metadata: {
          title: trackTitle || "",
          artist: artistName || "AIMuza Artist",
          album: "AIMuza WAV Export",
          publisher: publisherName || "AIMuza",
          copyright: `© ${new Date().getFullYear()} ${artistName || "AIMuza Artist"} via ${publisherName || "AIMuza"}`,
          comment: `Generated with AIMuza - aimuza.ru | Cabinet ID: ${cabinetId}`,
          TXXX_AIMUZA_CABINET_ID: cabinetId || "",
          TXXX_AIMUZA_PUBLISHER: publisherName || "AIMuza",
        },
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error(`[wav-cb] ffmpeg-api error ${resp.status}: ${errText}`);
      return null;
    }

    const result = await resp.json();
    let outputUrl = result.output_url;
    console.log(`[wav-cb] ffmpeg-api processed OK: ${outputUrl}`);

    if (outputUrl && outputUrl.includes("/output/")) {
      const filename = outputUrl.split("/output/").pop();
      if (filename) {
        const publicBase = ffmpegPublicUrl || baseUrl;
        outputUrl = `${publicBase}/output/${filename}`;
        console.log(`[wav-cb] Public URL: ${outputUrl}`);
      }
    }

    if (!outputUrl) {
      console.warn("[wav-cb] ffmpeg returned empty output_url");
      return null;
    }

    const isReachable = await isUsableAudioUrl(outputUrl, ffmpegApiUrl);
    if (!isReachable) {
      console.warn(`[wav-cb] ffmpeg output URL is not downloadable: ${outputUrl}`);
      return null;
    }

    return outputUrl;
  } catch (err) {
    console.error(`[wav-cb] ffmpeg processing error:`, err);
    return null;
  }
}

async function copyWavToStorage(
  supabase: ReturnType<typeof createClient>,
  externalUrl: string,
  trackId: string,
): Promise<string | null> {
  try {
    const response = await safeMediaFetch(externalUrl);
    if (!response.ok) {
      console.error(`[wav-cb] Storage copy download failed: ${response.status}`);
      return null;
    }

    const uint8Array = new Uint8Array(await response.arrayBuffer());
    if (uint8Array.length < 1000) {
      console.error(`[wav-cb] Storage copy file too small: ${uint8Array.length} bytes`);
      return null;
    }

    const filePath = `wav/${trackId}.wav`;
    const { error } = await supabase.storage
      .from("tracks")
      .upload(filePath, uint8Array, { contentType: "audio/wav", upsert: true });

    if (error) {
      console.error("[wav-cb] Storage upload error:", error);
      return null;
    }

    const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
    return `${baseUrl}/storage/v1/object/public/tracks/${filePath}`;
  } catch (error) {
    console.error("[wav-cb] Storage copy error:", error);
    return null;
  }
}

async function resumeReleasePackageBuild(
  trackId: string,
): Promise<void> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseServiceKey) return;

  try {
    const response = await fetch(`${supabaseUrl.replace(/\/$/, "")}/functions/v1/generate-release-package`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Authorization": `Bearer ${supabaseServiceKey}`,
      },
      body: JSON.stringify({ track_id: trackId }),
    });

    const payload = await response.text();
    console.log(`[wav-cb] release-package resume ${response.status}: ${payload}`);
  } catch (error) {
    console.error("[wav-cb] release-package resume failed:", error);
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null,{headers:corsHeaders});
  if (req.method !== 'POST' || !callbackAuthorized(req,'WAV_CALLBACK_SECRET')) return new Response('Unauthorized callback',{status:401});
  const supabase=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let claimedId: string | null=null;
  try {
    const payload=await req.json();
    const taskId=getTaskId(payload);
    if(!taskId || !/^[a-zA-Z0-9_-]{1,160}$/.test(taskId)) return new Response('Invalid task',{status:400});
    const {data:claimed,error:claimError}=await supabase.rpc('security_claim_wav_callback',{p_task_id:taskId});
    if(claimError) throw new Error('Callback claim failed');
    if(!claimed || claimed.length!==1) return new Response('Unknown or settled task',{status:409});
    const addon=claimed[0];claimedId=addon.id;
    const originalUrl=getWavUrl(payload);
    if(Number(payload.code)!==200 || !originalUrl) throw new Error('Provider conversion failed');
    const {data:track}=await supabase.from('tracks').select('user_id,title,performer_name,label_name').eq('id',addon.track_id).single();
    if(!track) throw new Error('Track missing');
    const {data:profile}=await supabase.from('profiles').select('username,display_name,short_id').eq('user_id',track.user_id).maybeSingle();
    const ffmpegUrl=Deno.env.get('FFMPEG_API_URL'),ffmpegKey=Deno.env.get('FFMPEG_API_SECRET');
    if(!ffmpegUrl||!ffmpegKey) throw new Error('Media processing unavailable');
    const processed=await processWavViaFfmpeg(originalUrl,track.title||'',track.performer_name||profile?.display_name||profile?.username||'AIMuza Artist',track.label_name||'AIMuza',profile?.short_id||track.user_id,ffmpegUrl,ffmpegKey,Deno.env.get('FFMPEG_PUBLIC_URL'));
    if(!processed) throw new Error('Media processing failed');
    const stored=await copyWavToStorage(supabase,processed,addon.track_id);
    if(!stored) throw new Error('Media persistence failed');
    const {data:completed,error:completeError}=await supabase.rpc('security_complete_wav',{p_addon_id:addon.id,p_result_url:stored});
    if(completeError||!completed) throw new Error('Settlement failed');
    const {data:pending}=await supabase.from('release_packages').select('id').eq('track_id',addon.track_id).eq('status','processing').maybeSingle();
    if(pending?.id) await resumeReleasePackageBuild(addon.track_id);
    return new Response(JSON.stringify({success:true}),{headers:{...corsHeaders,'Content-Type':'application/json'}});
  } catch {
    if(claimedId) {
      const {error}=await supabase.rpc('security_fail_wav',{p_addon_id:claimedId});
      if(error) console.error('WAV settlement requires retry');
    }
    return new Response(JSON.stringify({error:'WAV processing failed'}),{status:500,headers:corsHeaders});
  }
});
