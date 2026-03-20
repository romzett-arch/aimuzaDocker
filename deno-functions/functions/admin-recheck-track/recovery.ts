import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  AUDIO_RECOVERY_REQUIRED_MESSAGE,
  copyFirstAvailableFileToStorage,
  isManagedTrackStorageUrl,
} from "../suno-callback/audio-storage.ts";
import { getDurationFromFfmpeg } from "../suno-callback/ffmpeg-duration.ts";

export const SUNO_API_BASE = "https://api.sunoapi.org";

type RawSunoRecord = Record<string, unknown>;

export type RecoveryTrack = {
  id: string;
  user_id: string;
  title: string | null;
  description: string | null;
  audio_url: string | null;
  cover_url: string | null;
  duration: number | null;
  status: string | null;
  error_message?: string | null;
};

export type TrackRecoveryResult = {
  ok: boolean;
  action:
    | "already_local"
    | "recovered"
    | "missing_task_id"
    | "suno_api_error"
    | "no_audio_record"
    | "storage_copy_failed";
  message: string;
  trackId: string;
  taskId: string | null;
  sunoStatus?: string | null;
};

type NormalizedSunoRecord = {
  id: string | null;
  audioUrl: string | null;
  audioUrls: string[];
  imageUrl: string | null;
  imageUrls: string[];
  duration: unknown;
};

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function resolveTrackDuration(
  directDuration: unknown,
  candidateUrls: Array<string | null | undefined>,
): Promise<number | null> {
  if (directDuration != null) {
    const parsed = Math.round(Number(directDuration));
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }

  for (const url of candidateUrls) {
    if (!url) continue;
    const ffmpegDur = await getDurationFromFfmpeg(url);
    if (ffmpegDur != null && ffmpegDur > 0) {
      return ffmpegDur;
    }
  }

  return null;
}

export function extractTaskId(description: string | null | undefined): string | null {
  const match = description?.match(/\[task_id:\s*([^\]]+)\]/);
  return match?.[1]?.trim() || null;
}

function normalizeSunoRecords(records: RawSunoRecord[]): NormalizedSunoRecord[] {
  return records.map((record) => {
    const audioUrls = [
      record.sourceAudioUrl, record.source_audio_url,
      record.audioUrl, record.audio_url,
      record.sourceStreamAudioUrl, record.source_stream_audio_url,
      record.streamAudioUrl, record.stream_audio_url,
    ].filter((url): url is string => typeof url === "string" && url.startsWith("http"));

    const imageUrls = [
      record.sourceImageUrl, record.source_image_url,
      record.imageUrl, record.image_url,
    ].filter((url): url is string => typeof url === "string" && url.startsWith("http"));

    return {
      id: typeof record.id === "string" ? record.id : null,
      audioUrl: audioUrls[0] || null,
      audioUrls,
      imageUrl: imageUrls[0] || null,
      imageUrls,
      duration: record.duration,
    };
  });
}

async function fetchWithRetry(url: string, options: RequestInit, maxRetries = 2): Promise<Response> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 10000);
      const response = await fetch(url, { ...options, signal: controller.signal });
      clearTimeout(timeoutId);
      return response;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (lastError.name === "AbortError") {
        throw new Error("Request timeout");
      }
      if (attempt < maxRetries) {
        await delay(1000 * (attempt + 1));
      }
    }
  }

  throw lastError || new Error("Failed after retries");
}

async function fetchSunoTaskRecords(taskId: string): Promise<{ status: string | null; records: NormalizedSunoRecord[] }> {
  const response = await fetchWithRetry(
    `${SUNO_API_BASE}/api/v1/generate/record-info?taskId=${encodeURIComponent(taskId)}`,
    {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${Deno.env.get("SUNO_API_KEY")}`,
      },
    },
  );

  const payload = await response.json();
  if (!response.ok || payload?.code !== 200 || !payload?.data) {
    throw new Error(payload?.msg || payload?.error || `Suno API error: ${response.status}`);
  }

  const records = payload.data.response?.sunoData || payload.data.data || [];
  return {
    status: payload.data.status || null,
    records: normalizeSunoRecords(records),
  };
}

function pickRecordForTrack(records: NormalizedSunoRecord[], title: string | null | undefined): NormalizedSunoRecord | null {
  const isV2 = /\(v2\)\s*$/.test(title || "");
  const recordIndex = isV2 ? 1 : 0;
  return records[recordIndex] || null;
}

export async function recoverGeneratedTrack(
  supabaseAdmin: SupabaseClient,
  track: RecoveryTrack,
  options?: {
    persistFailure?: boolean;
    clearAudioOnFailure?: boolean;
  },
): Promise<TrackRecoveryResult> {
  const persistFailure = options?.persistFailure ?? false;
  const clearAudioOnFailure = options?.clearAudioOnFailure ?? false;

  if (isManagedTrackStorageUrl(track.audio_url) && track.status === "completed") {
    return {
      ok: true,
      action: "already_local",
      message: "Трек уже сохранён в локальном storage",
      trackId: track.id,
      taskId: extractTaskId(track.description),
    };
  }

  const taskId = extractTaskId(track.description);
  if (!taskId) {
    return {
      ok: false,
      action: "missing_task_id",
      message: "У трека нет task_id для восстановления",
      trackId: track.id,
      taskId: null,
    };
  }

  let sunoStatus: string | null = null;
  let record: NormalizedSunoRecord | null = null;

  try {
    const response = await fetchSunoTaskRecords(taskId);
    sunoStatus = response.status;
    record = pickRecordForTrack(response.records, track.title);
  } catch (error) {
    return {
      ok: false,
      action: "suno_api_error",
      message: error instanceof Error ? error.message : "Не удалось получить данные из Suno API",
      trackId: track.id,
      taskId,
      sunoStatus,
    };
  }

  if (!record?.audioUrls.length) {
    return {
      ok: false,
      action: "no_audio_record",
      message: "Suno не вернул аудио для этого трека",
      trackId: track.id,
      taskId,
      sunoStatus,
    };
  }

  const finalAudioUrl = await copyFirstAvailableFileToStorage(
    supabaseAdmin,
    record.audioUrls,
    "tracks",
    `audio/${track.id}.mp3`,
  );

  let finalCoverUrl = track.cover_url;
  if (record.imageUrls.length > 0) {
    finalCoverUrl = await copyFirstAvailableFileToStorage(
      supabaseAdmin,
      record.imageUrls,
      "tracks",
      `covers/${track.id}.jpg`,
    ) || record.imageUrl || track.cover_url;
  }

  if (!finalAudioUrl) {
    if (persistFailure) {
      await supabaseAdmin
        .from("tracks")
        .update({
          audio_url: clearAudioOnFailure ? null : track.audio_url,
          cover_url: finalCoverUrl,
          status: "failed",
          error_message: AUDIO_RECOVERY_REQUIRED_MESSAGE,
          suno_audio_id: record.id,
        })
        .eq("id", track.id);

      await supabaseAdmin
        .from("generation_logs")
        .update({ status: "failed" })
        .eq("track_id", track.id);
    }

    return {
      ok: false,
      action: "storage_copy_failed",
      message: AUDIO_RECOVERY_REQUIRED_MESSAGE,
      trackId: track.id,
      taskId,
      sunoStatus,
    };
  }

  const duration = await resolveTrackDuration(record.duration, [finalAudioUrl, ...record.audioUrls]);

  await supabaseAdmin
    .from("tracks")
    .update({
      audio_url: finalAudioUrl,
      cover_url: finalCoverUrl,
      ...(duration != null ? { duration } : {}),
      status: "completed",
      error_message: null,
      suno_audio_id: record.id,
    })
    .eq("id", track.id);

  await supabaseAdmin
    .from("generation_logs")
    .update({ status: "completed" })
    .eq("track_id", track.id);

  return {
    ok: true,
    action: "recovered",
    message: "Трек успешно восстановлен и сохранён в локальный storage",
    trackId: track.id,
    taskId,
    sunoStatus,
  };
}
