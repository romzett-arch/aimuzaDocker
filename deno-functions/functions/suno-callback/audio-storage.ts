import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const TRACKS_PUBLIC_PREFIX = "/storage/v1/object/public/tracks/";
const STORAGE_UPLOAD_MAX_ATTEMPTS = 6;
const STORAGE_UPLOAD_BASE_DELAY_MS = 750;

export const AUDIO_RECOVERY_REQUIRED_MESSAGE =
  "Аудио сгенерировано, но временно не удалось сохранить его в библиотеку. Нажмите «Проверить статус» на карточке трека и попробуйте снова чуть позже.";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableStorageError(error: unknown): boolean {
  if (!error || typeof error !== "object") {
    return false;
  }

  const status = Reflect.get(error, "status");
  const statusCode = Reflect.get(error, "statusCode");
  const message = String(Reflect.get(error, "message") ?? "").toLowerCase();

  if (status === 429 || statusCode === 429 || statusCode === "429") {
    return true;
  }

  return message.includes("rate limit") || message.includes("too many requests");
}

export function isManagedTrackStorageUrl(url: string | null | undefined): boolean {
  if (!url) return false;

  const normalized = url.trim();
  if (!normalized) return false;

  if (normalized.startsWith(TRACKS_PUBLIC_PREFIX) || normalized.startsWith(TRACKS_PUBLIC_PREFIX.slice(1))) {
    return true;
  }

  try {
    const parsed = new URL(normalized);
    return parsed.pathname.startsWith(TRACKS_PUBLIC_PREFIX);
  } catch {
    return false;
  }
}

export async function copyFileToStorage(
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

    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("text/html")) {
      console.error(`Downloaded HTML instead of audio (content-type: ${contentType}), URL may be invalid`);
      return null;
    }

    const blob = await response.blob();
    const arrayBuffer = await blob.arrayBuffer();
    const uint8Array = new Uint8Array(arrayBuffer);

    const isAudio = filePath.endsWith(".mp3");
    const minSize = isAudio ? 10000 : 1000;
    if (uint8Array.length < minSize) {
      console.error(`File too small (${uint8Array.length} bytes, min ${minSize}), likely not valid audio`);
      return null;
    }

    if (isAudio && uint8Array.length > 3) {
      const isId3 = uint8Array[0] === 0x49 && uint8Array[1] === 0x44 && uint8Array[2] === 0x33;
      const isMpeg = uint8Array[0] === 0xff && (uint8Array[1] & 0xe0) === 0xe0;
      if (!isId3 && !isMpeg) {
        console.error(`File does not start with ID3 or MPEG sync (first bytes: ${uint8Array[0].toString(16)} ${uint8Array[1].toString(16)} ${uint8Array[2].toString(16)})`);
        return null;
      }
    }

    console.log(`Downloaded ${uint8Array.length} bytes, uploading to ${bucket}/${filePath}`);

    for (let attempt = 1; attempt <= STORAGE_UPLOAD_MAX_ATTEMPTS; attempt++) {
      const { error: uploadError } = await supabaseAdmin.storage
        .from(bucket)
        .upload(filePath, uint8Array, {
          contentType: blob.type || "application/octet-stream",
          upsert: true,
        });

      if (!uploadError) {
        const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
        const publicUrl = `${BASE_URL}/storage/v1/object/public/${bucket}/${filePath}`;

        console.log(`File uploaded successfully: ${publicUrl}`);
        return publicUrl;
      }

      console.error(`Upload error on attempt ${attempt}/${STORAGE_UPLOAD_MAX_ATTEMPTS}:`, uploadError);

      if (!isRetryableStorageError(uploadError) || attempt === STORAGE_UPLOAD_MAX_ATTEMPTS) {
        return null;
      }

      const delayMs = STORAGE_UPLOAD_BASE_DELAY_MS * Math.pow(2, attempt - 1);
      console.warn(`Storage rate limit hit, retrying in ${delayMs}ms...`);
      await sleep(delayMs);
    }
  } catch (err) {
    console.error(`Error copying file to storage:`, err);
    return null;
  }
}

export async function copyFirstAvailableFileToStorage(
  supabaseAdmin: SupabaseClient,
  externalUrls: Array<string | null | undefined>,
  bucket: string,
  filePath: string,
): Promise<string | null> {
  for (const url of externalUrls) {
    if (!url) continue;

    const storedUrl = await copyFileToStorage(supabaseAdmin, url, bucket, filePath);
    if (storedUrl) {
      return storedUrl;
    }
  }

  return null;
}
