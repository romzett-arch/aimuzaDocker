import { safeMediaFetch } from "../_shared/safe-media-fetch.ts";

export const releaseCoverFilename = "cover_3000x3000.jpg";
export const validCoverId = (value: unknown): value is string =>
  typeof value === "string" && /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i.test(value);

export async function respondWithCoverSource(url: string, headers: Record<string, string>) {
  try {
    const response = await safeMediaFetch(url);
    if (!response.ok || !response.body) {
      await response.body?.cancel();
      return new Response(null, { status: 404, headers });
    }
    return new Response(response.body, {
      headers: { ...headers, "Content-Type": "application/octet-stream", "Cache-Control": "private, no-store" },
    });
  } catch {
    return new Response(null, { status: 404, headers });
  }
}

export async function loadConfirmedCover(apiUrl: string, serviceKey: string, userId: string, coverId: string) {
  const response = await fetch(`${apiUrl.replace(/\/$/, "")}/functions/v1/release-package-cover`, {
    method: "POST",
    headers: { Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: userId, id: coverId }),
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`release_cover_unavailable:${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}
