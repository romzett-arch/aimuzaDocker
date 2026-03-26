import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import JSZip from "npm:jszip@3.10.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const TRACKS_BUCKET = "tracks";
const DEFAULT_BASE_URL = "https://aimuza.ru";

type ReleasePackageStatus = "processing" | "completed" | "failed";

interface ReleasePackageRow {
  id: string;
  track_id: string;
  user_id: string;
  status: ReleasePackageStatus;
  zip_url: string | null;
  mp3_url: string | null;
  wav_url: string | null;
  cover_url: string | null;
  genre_txt_url: string | null;
  certificate_url: string | null;
  certificate_pdf_url: string | null;
  blockchain_proof_url: string | null;
  requested_title: string | null;
  requested_performer_name: string | null;
  requested_author_name: string | null;
  requested_genre: string | null;
  requested_has_lyrics: boolean | null;
  requested_include_deposit: boolean | null;
  error_message: string | null;
}

interface ExistingReleasePackageState {
  id: string;
  requested_title: string | null;
  requested_performer_name: string | null;
  requested_author_name: string | null;
  requested_genre: string | null;
  requested_has_lyrics: boolean | null;
  requested_include_deposit: boolean | null;
}

interface WavPreparationResult {
  status: "ready" | "processing";
  wavUrl: string | null;
}

interface MusicVideoPreparationResult {
  status: "ready" | "processing";
  videoUrl: string | null;
}

interface ReleaseMetadata {
  artistName: string;
  authorName: string;
  genreName: string;
  publisherName: string;
  cabinetId: string;
  metadata: Record<string, string>;
}

function stripFfmpegRoute(url: string): string {
  return url.replace(/\/(clean-metadata|analyze|normalize|process-wav)\/?$/, "");
}

function sanitizeBaseName(value: string): string {
  return (value || "release-track")
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120) || "release-track";
}

function buildReleaseMetadata(track: {
  id: string;
  user_id: string;
  title: string | null;
  performer_name?: string | null;
  author_name?: string | null;
  music_author?: string | null;
  lyrics_author?: string | null;
  genre_name?: string | null;
  label_name?: string | null;
  profile?: {
    username?: string | null;
    display_name?: string | null;
    short_id?: string | null;
  } | null;
}): ReleaseMetadata {
  const artistName =
    track.performer_name?.trim()
    || track.profile?.display_name?.trim()
    || track.profile?.username?.trim()
    || "AIMuza Artist";
  const authorName =
    track.author_name?.trim()
    || track.music_author?.trim()
    || track.lyrics_author?.trim()
    || artistName;
  const genreName = track.genre_name?.trim() || "Без жанра";

  const publisherName = track.label_name?.trim() || "AIMuza";
  const cabinetId = track.profile?.short_id?.trim() || track.user_id;
  const title = track.title || "Без названия";

  return {
    artistName,
    authorName,
    genreName,
    publisherName,
    cabinetId,
    metadata: {
      title,
      artist: artistName,
      composer: authorName,
      genre: genreName,
      album: "AIMuza Release Package",
      publisher: publisherName,
      comment: `Prepared for release on aimuza.ru | Cabinet ID: ${cabinetId} | Track ID: ${track.id} | Author: ${authorName}`,
      copyright: `© ${new Date().getFullYear()} ${authorName} performed by ${artistName} via ${publisherName}`,
      TXXX_AIMUZA_TRACK_ID: track.id,
      TXXX_AIMUZA_USER_ID: track.user_id,
      TXXX_AIMUZA_CABINET_ID: cabinetId,
      TXXX_AIMUZA_ARTIST: artistName,
      TXXX_AIMUZA_AUTHOR: authorName,
      TXXX_AIMUZA_PUBLISHER: publisherName,
      TXXX_AIMUZA_RELEASE_PACKAGE: "true",
      TXXX_AIMUZA_WEBSITE: "aimuza.ru",
    },
  };
}

async function loadProfileIdentity(
  supabase: ReturnType<typeof createClient>,
  userId: string,
): Promise<{ username: string | null; display_name: string | null; short_id: string | null }> {
  const { data } = await supabase
    .from("profiles")
    .select("username")
    .eq("user_id", userId)
    .maybeSingle();

  return {
    username: data?.username ?? null,
    display_name: null,
    short_id: null,
  };
}

function inferFileExtension(rawUrl: string | null | undefined, fallback: string): string {
  if (!rawUrl) return fallback;

  try {
    const pathname = new URL(rawUrl, DEFAULT_BASE_URL).pathname;
    const cleanPath = pathname.split("?")[0] ?? pathname;
    const ext = cleanPath.includes(".") ? cleanPath.slice(cleanPath.lastIndexOf(".")) : "";
    return ext || fallback;
  } catch {
    return fallback;
  }
}

function resolvePublicUrl(rawUrl: string, requestUrl: string): string {
  const baseUrl = Deno.env.get("BASE_URL") || new URL(requestUrl).origin || DEFAULT_BASE_URL;
  return new URL(rawUrl, baseUrl).toString();
}

function toInternalFetchUrl(
  rawUrl: string,
  requestUrl: string,
  ffmpegBaseUrl?: string,
  storageOrigin?: string,
): string {
  const resolved = resolvePublicUrl(rawUrl, requestUrl);
  const normalizedStorageOrigin = (storageOrigin || "").replace(/\/$/, "");
  const target = new URL(resolved);

  if (normalizedStorageOrigin && target.pathname.startsWith("/storage/v1/object/public/")) {
    return `${normalizedStorageOrigin}${target.pathname}${target.search}`;
  }

  if (ffmpegBaseUrl && target.pathname.startsWith("/api/ffmpeg/")) {
    return `${ffmpegBaseUrl.replace(/\/$/, "")}${target.pathname.replace(/^\/api\/ffmpeg/, "")}${target.search}`;
  }

  return resolved;
}

async function fetchBytes(
  rawUrl: string,
  requestUrl: string,
  ffmpegBaseUrl?: string,
  storageOrigin?: string,
): Promise<Uint8Array> {
  const response = await fetch(toInternalFetchUrl(rawUrl, requestUrl, ffmpegBaseUrl, storageOrigin));
  if (!response.ok) {
    throw new Error(`asset_download_failed:${response.status}`);
  }

  return new Uint8Array(await response.arrayBuffer());
}

async function uploadBytes(
  supabase: ReturnType<typeof createClient>,
  fileName: string,
  bytes: Uint8Array,
  contentType: string,
): Promise<void> {
  const { error } = await supabase.storage
    .from(TRACKS_BUCKET)
    .upload(fileName, new Blob([bytes], { type: contentType }), {
      upsert: true,
      contentType,
      cacheControl: "0",
    });

  if (error) {
    throw new Error(`upload_failed:${fileName}:${error.message}`);
  }
}

function buildStoragePublicUrl(fileName: string, requestUrl: string): string {
  const baseUrl = Deno.env.get("BASE_URL") || new URL(requestUrl).origin || DEFAULT_BASE_URL;
  return `${baseUrl.replace(/\/$/, "")}/storage/v1/object/public/${TRACKS_BUCKET}/${fileName}`;
}

async function upsertReleasePackage(
  supabase: ReturnType<typeof createClient>,
  trackId: string,
  userId: string,
  updates: Partial<ReleasePackageRow> & { status: ReleasePackageStatus },
): Promise<void> {
  const now = new Date().toISOString();
  const { data: existing, error: selectError } = await supabase
    .from("release_packages")
    .select("id, requested_title, requested_performer_name, requested_author_name, requested_genre, requested_has_lyrics, requested_include_deposit")
    .eq("track_id", trackId)
    .maybeSingle<ExistingReleasePackageState>();

  if (selectError) {
    throw new Error(`release_package_lookup_failed:${selectError.message}`);
  }

  const payload = {
    user_id: userId,
    status: updates.status,
    zip_url: updates.zip_url ?? null,
    mp3_url: updates.mp3_url ?? null,
    wav_url: updates.wav_url ?? null,
    cover_url: updates.cover_url ?? null,
    genre_txt_url: updates.genre_txt_url ?? null,
    certificate_url: updates.certificate_url ?? null,
    certificate_pdf_url: updates.certificate_pdf_url ?? null,
    blockchain_proof_url: updates.blockchain_proof_url ?? null,
    requested_title: updates.requested_title ?? existing?.requested_title ?? null,
    requested_performer_name: updates.requested_performer_name ?? existing?.requested_performer_name ?? null,
    requested_author_name: updates.requested_author_name ?? existing?.requested_author_name ?? null,
    requested_genre: updates.requested_genre ?? existing?.requested_genre ?? null,
    requested_has_lyrics: updates.requested_has_lyrics ?? existing?.requested_has_lyrics ?? null,
    requested_include_deposit: updates.requested_include_deposit ?? existing?.requested_include_deposit ?? null,
    error_message: updates.error_message ?? null,
    updated_at: now,
  };

  if (existing?.id) {
    const { error: updateError } = await supabase
      .from("release_packages")
      .update(payload)
      .eq("id", existing.id);

    if (updateError) {
      throw new Error(`release_package_update_failed:${updateError.message}`);
    }

    return;
  }

  const { error: insertError } = await supabase
    .from("release_packages")
    .insert({
      id: crypto.randomUUID(),
      track_id: trackId,
      created_at: now,
      ...payload,
    });

  if (insertError) {
    throw new Error(`release_package_insert_failed:${insertError.message}`);
  }
}

function buildReleaseInfoText(input: {
  title: string;
  artistName: string;
  authorName: string;
  genreName: string;
  publisherName: string;
  includeDeposit: boolean;
}): string {
  return [
    "AIMuza Release Package",
    "",
    `Title: ${input.title}`,
    `Performer: ${input.artistName}`,
    `Author: ${input.authorName}`,
    `Genre: ${input.genreName}`,
    `Publisher: ${input.publisherName}`,
    `Deposit included: ${input.includeDeposit ? "yes" : "no"}`,
    `Generated at: ${new Date().toISOString()}`,
  ].join("\n");
}

async function callFfmpegJson(
  ffmpegBaseUrl: string,
  ffmpegApiSecret: string,
  endpoint: "normalize" | "process-wav",
  payload: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const response = await fetch(`${ffmpegBaseUrl}/${endpoint}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "x-api-key": ffmpegApiSecret,
    },
    body: JSON.stringify(payload),
  });

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = typeof data?.message === "string" ? data.message : `ffmpeg_${endpoint}_failed`;
    throw new Error(message);
  }

  return data;
}

async function invokeInternalFunction(
  supabaseUrl: string,
  supabaseServiceKey: string,
  functionName: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const response = await fetch(`${supabaseUrl.replace(/\/$/, "")}/functions/v1/${functionName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Authorization": `Bearer ${supabaseServiceKey}`,
    },
    body: JSON.stringify(body),
  });

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = typeof data?.error === "string" ? data.error : `${functionName}_failed`;
    throw new Error(message);
  }

  return data;
}

async function ensurePreparedWav(
  supabase: ReturnType<typeof createClient>,
  supabaseUrl: string,
  supabaseServiceKey: string,
  track: {
    id: string;
    suno_audio_id?: string | null;
  },
): Promise<WavPreparationResult> {
  const { data: addonService, error: addonServiceError } = await supabase
    .from("addon_services")
    .select("id")
    .eq("name", "convert_wav")
    .single();

  if (addonServiceError || !addonService?.id) {
    throw new Error("release_package_wav_service_missing");
  }

  const { data: existingAddon, error: existingAddonError } = await supabase
    .from("track_addons")
    .select("status, result_url")
    .eq("track_id", track.id)
    .eq("addon_service_id", addonService.id)
    .maybeSingle();

  if (existingAddonError) {
    throw new Error(`release_package_wav_lookup_failed:${existingAddonError.message}`);
  }

  if (existingAddon?.status === "completed" && existingAddon.result_url) {
    return { status: "ready", wavUrl: existingAddon.result_url };
  }

  if (existingAddon?.status === "processing") {
    return { status: "processing", wavUrl: null };
  }

  const convertResult = await invokeInternalFunction(
    supabaseUrl,
    supabaseServiceKey,
    "convert-to-wav",
    { track_id: track.id, audio_id: track.suno_audio_id ?? null },
  );

  const wavUrl = typeof convertResult?.wav_url === "string" ? convertResult.wav_url : null;
  if (wavUrl) {
    return { status: "ready", wavUrl };
  }

  return { status: "processing", wavUrl: null };
}

async function ensurePreparedMusicVideo(
  supabase: ReturnType<typeof createClient>,
  supabaseUrl: string,
  supabaseServiceKey: string,
  track: {
    id: string;
  },
  authorName: string,
): Promise<MusicVideoPreparationResult> {
  const { data: addonService, error: addonServiceError } = await supabase
    .from("addon_services")
    .select("id")
    .eq("name", "short_video")
    .single();

  if (addonServiceError || !addonService?.id) {
    throw new Error("release_package_music_video_service_missing");
  }

  const { data: existingAddon, error: existingAddonError } = await supabase
    .from("track_addons")
    .select("status, result_url")
    .eq("track_id", track.id)
    .eq("addon_service_id", addonService.id)
    .maybeSingle();

  if (existingAddonError) {
    throw new Error(`release_package_music_video_lookup_failed:${existingAddonError.message}`);
  }

  if (existingAddon?.status === "completed" && typeof existingAddon.result_url === "string" && existingAddon.result_url.startsWith("http")) {
    return { status: "ready", videoUrl: existingAddon.result_url };
  }

  if (existingAddon?.status === "processing") {
    const refreshResult = await invokeInternalFunction(
      supabaseUrl,
      supabaseServiceKey,
      "generate-music-video",
      { track_id: track.id, author: authorName || undefined },
    );

    const refreshedVideoUrl = typeof refreshResult?.video_url === "string" ? refreshResult.video_url : null;
    if (refreshedVideoUrl) {
      return { status: "ready", videoUrl: refreshedVideoUrl };
    }

    return { status: "processing", videoUrl: null };
  }

  const generateResult = await invokeInternalFunction(
    supabaseUrl,
    supabaseServiceKey,
    "generate-music-video",
    { track_id: track.id, author: authorName || undefined },
  );

  const videoUrl = typeof generateResult?.video_url === "string" ? generateResult.video_url : null;
  if (videoUrl) {
    return { status: "ready", videoUrl };
  }

  return { status: "processing", videoUrl: null };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const ffmpegApiUrl = Deno.env.get("FFMPEG_API_URL");
  const ffmpegApiSecret = Deno.env.get("FFMPEG_API_SECRET");
  const storageOrigin = Deno.env.get("SUPABASE_URL") || Deno.env.get("BASE_URL") || DEFAULT_BASE_URL;
  let requestedTrackId: string | null = null;
  let requestedUserId: string | null = null;
  let isInternalCall = false;

  if (!ffmpegApiUrl || !ffmpegApiSecret) {
    return new Response(
      JSON.stringify({ success: false, error: "FFmpeg API unavailable" }),
      { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const ffmpegBaseUrl = stripFfmpegRoute(ffmpegApiUrl);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    let userId: string | null = null;
    if (authHeader === `Bearer ${supabaseServiceKey}`) {
      isInternalCall = true;
    } else {
      const userClient = createClient(supabaseUrl, supabaseAnonKey, {
        global: { headers: { Authorization: authHeader } },
      });
      const {
        data: { user },
        error: userError,
      } = await userClient.auth.getUser();

      if (userError || !user) {
        return new Response(
          JSON.stringify({ success: false, error: "Invalid token" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      userId = user.id;
    }

    const body = await req.json().catch(() => ({}));
    const trackId = typeof body?.track_id === "string" ? body.track_id : "";
    const requestedReleaseTitle = typeof body?.release_title === "string" ? body.release_title.trim() : "";
    const requestedPerformerName = typeof body?.performer_name === "string" ? body.performer_name.trim() : "";
    const requestedAuthorName = typeof body?.author_name === "string" ? body.author_name.trim() : "";
    const requestedReleaseGenre = typeof body?.release_genre === "string" ? body.release_genre.trim() : "";
    const requestedHasLyrics = typeof body?.has_lyrics === "boolean" ? body.has_lyrics : null;
    const requestedIncludeDeposit = typeof body?.include_deposit === "boolean" ? body.include_deposit : null;
    const forceRegenerate = body?.force_regenerate === true;
    requestedTrackId = trackId || null;

    if (!trackId) {
      return new Response(
        JSON.stringify({ success: false, error: "track_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    if (!isInternalCall) {
      const { data: tierData, error: tierError } = await supabase.rpc("get_user_subscription_tier" as never, {
        p_user_id: userId,
      });

      if (tierError) {
        throw new Error(`subscription_check_failed:${tierError.message}`);
      }

      if ((tierData as { tier_key?: string } | null)?.tier_key !== "label") {
        return new Response(
          JSON.stringify({ success: false, error: "release_package_requires_label_tier" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select(`
        id, user_id, title, audio_url, wav_url, cover_url, status, source_type, created_at, suno_audio_id, lyrics,
        performer_name, label_name, music_author, lyrics_author,
        genre:genres(name_ru, name)
      `)
      .eq("id", trackId)
      .single();

    if (trackError || !track) {
      return new Response(
        JSON.stringify({ success: false, error: "track_not_found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    requestedUserId = track.user_id;

    if (!isInternalCall && track.user_id !== userId) {
      return new Response(
        JSON.stringify({ success: false, error: "access_denied" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if ((track.source_type || "generated") !== "generated") {
      return new Response(
        JSON.stringify({ success: false, error: "release_package_available_only_for_generated_tracks" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (track.status !== "completed" || !track.audio_url || !track.cover_url) {
      return new Response(
        JSON.stringify({ success: false, error: "track_not_ready_for_release_package" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: existingPackage } = await supabase
      .from("release_packages")
      .select("status, zip_url, mp3_url, wav_url, cover_url, genre_txt_url, certificate_url, certificate_pdf_url, blockchain_proof_url, requested_title, requested_performer_name, requested_author_name, requested_genre, requested_has_lyrics, requested_include_deposit, error_message")
      .eq("track_id", trackId)
      .maybeSingle();

    if (!forceRegenerate && existingPackage?.status === "completed" && existingPackage.zip_url) {
      return new Response(
        JSON.stringify({ success: true, status: "completed", zip_url: existingPackage.zip_url }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const trackTitle = requestedReleaseTitle || existingPackage?.requested_title || track.title || "Без названия";
    const safeBaseName = sanitizeBaseName(trackTitle);
    const performerName = requestedPerformerName || existingPackage?.requested_performer_name || track.performer_name || "";
    const authorName = requestedAuthorName || existingPackage?.requested_author_name || track.music_author || track.lyrics_author || performerName || "";
    const genreName = requestedReleaseGenre || existingPackage?.requested_genre || (track as { genre?: { name_ru?: string | null; name?: string | null } | null }).genre?.name_ru
      || (track as { genre?: { name?: string | null } | null }).genre?.name
      || "Без жанра";
    const hasLyrics = requestedHasLyrics ?? existingPackage?.requested_has_lyrics ?? Boolean(track.lyrics && track.lyrics.trim().length > 0);
    const includeDeposit = requestedIncludeDeposit ?? existingPackage?.requested_include_deposit ?? true;

    await upsertReleasePackage(supabase, trackId, track.user_id, {
      status: "processing",
      requested_title: trackTitle,
      requested_performer_name: performerName || null,
      requested_author_name: authorName || null,
      requested_genre: genreName,
      requested_has_lyrics: hasLyrics,
      requested_include_deposit: includeDeposit,
      error_message: null,
    });

    const wavPreparation = await ensurePreparedWav(supabase, supabaseUrl, supabaseServiceKey, track);
    if (wavPreparation.status === "processing" || !wavPreparation.wavUrl) {
      return new Response(
        JSON.stringify({ success: true, status: "processing", message: "release_package_waiting_for_wav" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const profileIdentity = await loadProfileIdentity(supabase, track.user_id);
    const releaseMeta = buildReleaseMetadata({
      ...track,
      title: trackTitle,
      performer_name: performerName || track.performer_name,
      author_name: authorName,
      genre_name: genreName,
      profile: profileIdentity,
    });
    const { metadata } = releaseMeta;

    const musicVideoPreparation = await ensurePreparedMusicVideo(
      supabase,
      supabaseUrl,
      supabaseServiceKey,
      track,
      releaseMeta.artistName,
    );
    if (musicVideoPreparation.status === "processing" || !musicVideoPreparation.videoUrl) {
      return new Response(
        JSON.stringify({ success: true, status: "processing", message: "release_package_waiting_for_music_video" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const mp3InputUrl = toInternalFetchUrl(track.audio_url, req.url, ffmpegBaseUrl, storageOrigin);
    const mp3Result = await callFfmpegJson(ffmpegBaseUrl, ffmpegApiSecret, "normalize", {
      audio_url: mp3InputUrl,
      target_lufs: -14,
      strip_metadata: true,
      brand_metadata: true,
      metadata,
    });
    const mp3Url = String(mp3Result.output_url || mp3Result.normalized_url || "");
    if (!mp3Url) {
      throw new Error("release_package_mp3_missing");
    }

    const wavUrl = wavPreparation.wavUrl;

    const coverBytes = await fetchBytes(track.cover_url, req.url, ffmpegBaseUrl, storageOrigin);
    const mp3Bytes = await fetchBytes(mp3Url, req.url, ffmpegBaseUrl, storageOrigin);
    const wavBytes = await fetchBytes(wavUrl, req.url, ffmpegBaseUrl, storageOrigin);
    const musicVideoBytes = await fetchBytes(musicVideoPreparation.videoUrl, req.url, ffmpegBaseUrl, storageOrigin);

    const genreBytes = new TextEncoder().encode(`${genreName}\n${hasLyrics ? "с текстом" : "без текста"}\n`);
    const releaseInfoBytes = new TextEncoder().encode(buildReleaseInfoText({
      title: trackTitle,
      artistName: releaseMeta.artistName,
      authorName: releaseMeta.authorName,
      genreName,
      publisherName: releaseMeta.publisherName,
      includeDeposit,
    }));
    const genreTxtUrl = null;

    const { data: deposit } = includeDeposit
      ? await supabase
        .from("track_deposits")
        .select("certificate_url, pdf_url, blockchain_proof_url")
        .eq("track_id", trackId)
        .eq("status", "completed")
        .order("completed_at", { ascending: false })
        .limit(1)
        .maybeSingle()
      : { data: null };

    const zip = new JSZip();
    zip.file(`${safeBaseName}.mp3`, mp3Bytes);
    zip.file(`${safeBaseName}.wav`, wavBytes);
    zip.file(`${safeBaseName}.mp4`, musicVideoBytes);
    zip.file(`cover${inferFileExtension(track.cover_url, ".jpg")}`, coverBytes);
    zip.file("genre.txt", genreBytes);
    zip.file("release-info.txt", releaseInfoBytes);

    if (deposit?.pdf_url) {
      const pdfBytes = await fetchBytes(deposit.pdf_url, req.url, ffmpegBaseUrl, storageOrigin);
      zip.file("certificate.pdf", pdfBytes);
    } else if (deposit?.certificate_url) {
      const htmlBytes = await fetchBytes(deposit.certificate_url, req.url, ffmpegBaseUrl, storageOrigin);
      zip.file("certificate.html", htmlBytes);
    }

    if (deposit?.blockchain_proof_url) {
      const proofBytes = await fetchBytes(deposit.blockchain_proof_url, req.url, ffmpegBaseUrl, storageOrigin);
      zip.file("proof.ots", proofBytes);
    }

    const zipBytes = await zip.generateAsync({
      type: "uint8array",
      compression: "DEFLATE",
      compressionOptions: { level: 6 },
    });

    const zipFileName = `release-packages/${trackId}/release-package.zip`;
    await uploadBytes(supabase, zipFileName, zipBytes, "application/zip");
    const zipUrl = buildStoragePublicUrl(zipFileName, req.url);

    await upsertReleasePackage(supabase, trackId, track.user_id, {
      status: "completed",
      zip_url: zipUrl,
      mp3_url: mp3Url,
      wav_url: wavUrl,
      cover_url: resolvePublicUrl(track.cover_url, req.url),
      genre_txt_url: genreTxtUrl,
      certificate_url: deposit?.certificate_url ?? null,
      certificate_pdf_url: deposit?.pdf_url ?? null,
      blockchain_proof_url: deposit?.blockchain_proof_url ?? null,
      error_message: null,
    });

    return new Response(
      JSON.stringify({
        success: true,
        status: "completed",
        zip_url: zipUrl,
        mp3_url: mp3Url,
        wav_url: wavUrl,
        cover_url: resolvePublicUrl(track.cover_url, req.url),
        genre_txt_url: genreTxtUrl,
        certificate_url: deposit?.certificate_url ?? null,
        certificate_pdf_url: deposit?.pdf_url ?? null,
        blockchain_proof_url: deposit?.blockchain_proof_url ?? null,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("[generate-release-package] Error:", message);

    try {
      if (requestedTrackId && requestedUserId) {
        const supabase = createClient(supabaseUrl, supabaseServiceKey);
        await upsertReleasePackage(supabase, requestedTrackId, requestedUserId, {
          status: "failed",
          error_message: message,
        });
      }
    } catch (persistError) {
      console.error("[generate-release-package] Failed to persist error:", persistError);
    }

    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
