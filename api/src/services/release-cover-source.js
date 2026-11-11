const maxReferenceBytes = 5 * 1024 * 1024;

export async function loadTrackCover(trackId, authorization) {
  const base = process.env.DENO_FUNCTIONS_URL;
  if (!base || !authorization) throw new Error('Cover source unavailable');
  const response = await fetch(`${base.replace(/\/$/, '')}/functions/v1/generate-release-package`, {
    method: 'POST',
    headers: { Authorization: authorization, 'Content-Type': 'application/json' },
    body: JSON.stringify({ track_id: trackId, action: 'cover-source' }),
    redirect: 'error',
    signal: AbortSignal.timeout(25_000),
  });
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    throw new Error('Track cover unavailable');
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body) {
    length += chunk.length;
    if (length > maxReferenceBytes) throw new Error('Track cover is too large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, length);
}
