const maxBytes = 5 * 1024 * 1024;
const cdn = /(?:^|\.)(?:mycdn\.me|okcdn\.ru|oneme\.ru)$/i;

export async function fetchMaxPhoto(rawUrl) {
  const url = new URL(rawUrl);
  if (url.protocol !== "https:" || !cdn.test(url.hostname) || url.port || url.username || url.password) {
    throw new Error("Unexpected MAX photo URL");
  }
  const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(15_000) });
  if (!response.ok || !response.body || Number(response.headers.get("content-length")) > maxBytes) {
    await response.body?.cancel();
    const error = new Error("MAX photo unavailable");
    error.status = response.status;
    throw error;
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > maxBytes) throw new Error("Photo too large");
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks, size);
  let type;
  if (bytes.subarray(0, 3).equals(Buffer.from("ffd8ff", "hex"))) type = "image/jpeg";
  if (bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"))) type = "image/png";
  if (bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") type = "image/webp";
  if (!type) throw new Error("Unsupported MAX photo format");
  return { bytes, type };
}
