import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import JSZip from "npm:jszip@3.10.1";
import { beginReleasePackage, finishReleasePackage } from "./package-state.ts";
import { resolveReleaseAccess, releaseAccessDenied } from "./promo.ts";
import { loadConfirmedCover, releaseCoverFilename, respondWithCoverSource, validCoverId } from "./cover.ts";
import { buildReleaseMetadata, buildReleaseInfoText, buildGenreText, loadProfileIdentity, sanitizeBaseName, sha256Hex } from "./metadata.ts";
import { buildStoragePublicUrl, callFfmpegJson, DEFAULT_BASE_URL, fetchBytes, stripFfmpegRoute, toInternalFetchUrl, uploadBytes } from "./media.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const RELEASE_PACKAGE_FILE_NAME = "release-package-audio-v3.zip";

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
  let packageLease: string | null = null;
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
    const requestedCoverId = body?.cover_id;
    if (requestedCoverId != null && !validCoverId(requestedCoverId)) {
      return Response.json({ success: false, error: "invalid_release_cover" }, { status: 400, headers: corsHeaders });
    }
    const trackId = typeof body?.track_id === "string" ? body.track_id : "";
    const requestedReleaseTitle = typeof body?.release_title === "string" ? body.release_title.trim() : "";
    const requestedPerformerName = typeof body?.performer_name === "string" ? body.performer_name.trim() : "";
    const requestedAuthorName = typeof body?.author_name === "string" ? body.author_name.trim() : "";
    const requestedReleaseGenre = typeof body?.release_genre === "string" ? body.release_genre.trim() : "";
    const requestedHasLyrics = typeof body?.has_lyrics === "boolean" ? body.has_lyrics : null;
    const requestedIncludeDeposit = typeof body?.include_deposit === "boolean" ? body.include_deposit : null;
    const requestedMoveToMyReleases = typeof body?.move_to_my_releases === "boolean" ? body.move_to_my_releases : null;
    const forceRegenerate = body?.force_regenerate === true;
    requestedTrackId = trackId || null;

    if (!trackId) {
      return new Response(
        JSON.stringify({ success: false, error: "track_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const access = isInternalCall ? "internal" : await resolveReleaseAccess(supabase, userId!, trackId, body?.use_promo === true);
    if (!access) return releaseAccessDenied(corsHeaders);

    const { data: track, error: trackError } = await supabase
      .from("tracks")
      .select(`
        id, user_id, title, description, audio_url, master_audio_url, normalized_audio_url, wav_url, cover_url, status, source_type, created_at, suno_audio_id, lyrics,
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

    if (body?.action === "cover-source") {
      return track.cover_url && track.status === "completed"
        ? await respondWithCoverSource(toInternalFetchUrl(track.cover_url, req.url, ffmpegBaseUrl, storageOrigin), corsHeaders)
        : new Response(null, { status: 404, headers: corsHeaders });
    }

    if ((track.source_type || "generated") !== "generated") {
      return new Response(
        JSON.stringify({ success: false, error: "release_package_available_only_for_generated_tracks" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (track.status !== "completed" || !track.audio_url) {
      return new Response(
        JSON.stringify({ success: false, error: "track_not_ready_for_release_package" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: existingPackage } = await supabase
      .from("release_packages")
      .select("lease_until, status, zip_url, mp3_url, wav_url, cover_url, genre_txt_url, certificate_url, certificate_pdf_url, blockchain_proof_url, requested_title, requested_performer_name, requested_author_name, requested_genre, requested_cover_id, requested_has_lyrics, requested_include_deposit, requested_move_to_my_releases, error_message")
      .eq("track_id", trackId)
      .maybeSingle();

    if (existingPackage?.status === "processing" && Date.parse(existingPackage.lease_until) > Date.now()) {
      return Response.json({ success: true, status: "processing" }, { status: 202, headers: corsHeaders });
    }

    if (
      !forceRegenerate
      && (!requestedCoverId || requestedCoverId === existingPackage?.requested_cover_id)
      && existingPackage?.status === "completed"
      && existingPackage.zip_url?.includes(`/${RELEASE_PACKAGE_FILE_NAME}`)
    ) {
      return new Response(
        JSON.stringify({ success: true, status: "completed", zip_url: existingPackage.zip_url }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const coverId = requestedCoverId ?? existingPackage?.requested_cover_id;
    const coverBytes = coverId ? await loadConfirmedCover(supabaseUrl, supabaseServiceKey, track.user_id, trackId, coverId) : null;
    if (!coverBytes) {
      return Response.json({ success: false, error: "release_cover_unavailable" }, { status: 400, headers: corsHeaders });
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

    const claim = await beginReleasePackage(supabase, trackId, track.user_id, access === "promo", {
      requested_title: trackTitle,
      requested_performer_name: performerName || null,
      requested_author_name: authorName || null,
      requested_genre: genreName,
      requested_cover_id: coverId,
      requested_has_lyrics: hasLyrics,
      requested_include_deposit: includeDeposit,
      requested_move_to_my_releases: requestedMoveToMyReleases ?? null,
    });
    if (claim === "denied") return releaseAccessDenied(corsHeaders);
    if (claim === "processing") {
      return Response.json({ success: true, status: "processing" }, { status: 202, headers: corsHeaders });
    }
    packageLease = claim;

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

    const masterUrl = track.master_audio_url || track.normalized_audio_url || track.audio_url;
    const masterInputUrl = toInternalFetchUrl(masterUrl, req.url, ffmpegBaseUrl, storageOrigin);
    const metadataKey = await sha256Hex(JSON.stringify({ version: 3, trackId, masterUrl, metadata }));
    const mp3Result = await callFfmpegJson(ffmpegBaseUrl, ffmpegApiSecret, "clean-metadata", {
      audio_url: masterInputUrl,
      metadata,
      cache_key: metadataKey,
    });
    const mp3Url = String(mp3Result.output_url || mp3Result.cleaned_url || "");
    if (!mp3Url) {
      throw new Error("release_package_mp3_missing");
    }

    const wavResult = await callFfmpegJson(ffmpegBaseUrl, ffmpegApiSecret, "convert-format", {
      audio_url: masterInputUrl,
      format: "wav",
      metadata,
      cache_key: await sha256Hex(JSON.stringify({ version: 3, trackId, masterUrl, metadata, format: "wav" })),
    });
    const wavUrl = String(wavResult.output_url || "");
    if (!wavUrl) throw new Error("release_package_distribution_audio_missing");

    const mp3Bytes = await fetchBytes(mp3Url, req.url, ffmpegBaseUrl, storageOrigin);
    const wavBytes = await fetchBytes(wavUrl, req.url, ffmpegBaseUrl, storageOrigin);

    const promptText = track.description || null;
    const lyricsText = track.lyrics || null;
    const genreBytes = new TextEncoder().encode(buildGenreText({
      genreName,
      hasLyrics,
      lyricsText,
      promptText,
    }));
    const releaseInfoBytes = new TextEncoder().encode(buildReleaseInfoText({
      title: trackTitle,
      artistName: releaseMeta.artistName,
      authorName: releaseMeta.authorName,
      genreName,
      publisherName: releaseMeta.publisherName,
      includeDeposit,
      promptText,
      lyricsText,
      includeLyricsBlock: hasLyrics,
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
    zip.file("genre.txt", genreBytes);
    zip.file("release-info.txt", releaseInfoBytes);
    zip.file(releaseCoverFilename, coverBytes);

    if (deposit?.pdf_url) {
      const pdfBytes = await fetchBytes(deposit.pdf_url, req.url, ffmpegBaseUrl, storageOrigin);
      zip.file("certificate.pdf", pdfBytes);
    } else if (deposit?.certificate_url) {
      const htmlBytes = await fetchBytes(deposit.certificate_url, req.url, ffmpegBaseUrl, storageOrigin);
      zip.file("certificate.html", htmlBytes);
    }

    const zipBytes = await zip.generateAsync({
      type: "uint8array",
      compression: "DEFLATE",
      compressionOptions: { level: 6 },
    });

    const zipFileName = `release-packages/${trackId}/${packageLease}/${RELEASE_PACKAGE_FILE_NAME}`;
    const coverPath = `release-packages/${trackId}/${packageLease}/${releaseCoverFilename}`;
    await uploadBytes(supabase, coverPath, coverBytes, "image/jpeg");
    const coverUrl = buildStoragePublicUrl(coverPath, req.url);
    await uploadBytes(supabase, zipFileName, zipBytes, "application/zip");
    const zipUrl = buildStoragePublicUrl(zipFileName, req.url);

    await finishReleasePackage(supabase, trackId, track.user_id, packageLease, {
      status: "completed",
      zip_url: zipUrl,
      mp3_url: mp3Url,
      wav_url: wavUrl,
      cover_url: coverUrl,
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
        cover_url: coverUrl,
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
      if (packageLease && requestedTrackId && requestedUserId) {
        const supabase = createClient(supabaseUrl, supabaseServiceKey);
        await finishReleasePackage(supabase, requestedTrackId, requestedUserId, packageLease, {
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
