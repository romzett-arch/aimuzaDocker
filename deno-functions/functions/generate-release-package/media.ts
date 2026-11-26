import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { safeMediaFetch } from "../_shared/safe-media-fetch.ts";

const TRACKS_BUCKET = "tracks";
export const DEFAULT_BASE_URL = "https://aimuza.ru";
const STORAGE_UPLOAD_MAX_ATTEMPTS = 12;
const STORAGE_UPLOAD_BASE_DELAY_MS = 5_000;
const STORAGE_UPLOAD_MAX_DELAY_MS = 45_000;


function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableStorageError(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;

  const candidate = error as { status?: number; statusCode?: string | number; message?: string };
  const statusCode = String(candidate.statusCode ?? candidate.status ?? "");
  const message = String(candidate.message ?? "");

  return statusCode === "429"
    || statusCode === "408"
    || statusCode === "409"
    || /rate limit/i.test(message)
    || /too many requests/i.test(message)
    || /resource already exists/i.test(message);
}

export function stripFfmpegRoute(url: string): string {
  return url.replace(/\/(clean-metadata|analyze|normalize|process-wav|convert-format)\/?$/, "");
}

export function resolvePublicUrl(rawUrl: string, requestUrl: string): string {
  const baseUrl = Deno.env.get("BASE_URL") || new URL(requestUrl).origin || DEFAULT_BASE_URL;
  return new URL(rawUrl, baseUrl).toString();
}

export function toInternalFetchUrl(
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

export async function fetchBytes(
  rawUrl: string,
  requestUrl: string,
  ffmpegBaseUrl?: string,
  storageOrigin?: string,
): Promise<Uint8Array> {
  const response = await safeMediaFetch(toInternalFetchUrl(rawUrl, requestUrl, ffmpegBaseUrl, storageOrigin));
  if (!response.ok) {
    throw new Error(`asset_download_failed:${response.status}`);
  }

  return new Uint8Array(await response.arrayBuffer());
}

export async function uploadBytes(
  supabase: SupabaseClient,
  fileName: string,
  bytes: Uint8Array,
  contentType: string,
): Promise<void> {
  for (let attempt = 1; attempt <= STORAGE_UPLOAD_MAX_ATTEMPTS; attempt++) {
    const { error } = await supabase.storage
      .from(TRACKS_BUCKET)
      .upload(fileName, bytes, {
        upsert: true,
        contentType,
        cacheControl: "0",
      });

    if (!error) {
      return;
    }

    console.error(`[generate-release-package] Upload error on attempt ${attempt}/${STORAGE_UPLOAD_MAX_ATTEMPTS}:`, error);

    if (!isRetryableStorageError(error) || attempt === STORAGE_UPLOAD_MAX_ATTEMPTS) {
      throw new Error(`upload_failed:${fileName}:${error.message}`);
    }

    const delayMs = Math.min(
      STORAGE_UPLOAD_MAX_DELAY_MS,
      STORAGE_UPLOAD_BASE_DELAY_MS * Math.pow(2, attempt - 1),
    );
    console.warn(`[generate-release-package] Storage rate limit hit, retrying in ${delayMs}ms...`);
    await sleep(delayMs);
  }
}

export function buildStoragePublicUrl(fileName: string, requestUrl: string): string {
  const baseUrl = Deno.env.get("BASE_URL") || new URL(requestUrl).origin || DEFAULT_BASE_URL;
  return `${baseUrl.replace(/\/$/, "")}/storage/v1/object/public/${TRACKS_BUCKET}/${fileName}`;
}

export async function callFfmpegJson(
  ffmpegBaseUrl: string,
  ffmpegApiSecret: string,
  endpoint: "clean-metadata" | "convert-format",
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
