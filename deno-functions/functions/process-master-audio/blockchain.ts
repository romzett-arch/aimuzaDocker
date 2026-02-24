export async function computeFileHash(fileUrl: string): Promise<string | null> {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 120000);
    const resp = await fetch(fileUrl, { signal: controller.signal });
    clearTimeout(timeoutId);

    if (!resp.ok) {
      console.error(`[SHA-256] Download failed: ${resp.status}`);
      return null;
    }

    const buffer = await resp.arrayBuffer();
    const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
    const hashHex = Array.from(new Uint8Array(hashBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    console.log(`[SHA-256] Computed: ${hashHex} (${(buffer.byteLength / 1024 / 1024).toFixed(1)}MB)`);
    return hashHex;
  } catch (e) {
    console.error(`[SHA-256] Failed:`, e);
    return null;
  }
}

export async function submitToOpenTimestamps(hashHex: string): Promise<Uint8Array | null> {
  const hashBytes = new Uint8Array(
    hashHex.match(/.{2}/g)!.map(byte => parseInt(byte, 16))
  );

  const calendars = [
    'https://a.pool.opentimestamps.org/digest',
    'https://b.pool.opentimestamps.org/digest',
    'https://finney.calendar.eternitywall.com/digest',
  ];

  for (const calendar of calendars) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 15000);

      const resp = await fetch(calendar, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/octet-stream',
          'Accept': 'application/vnd.opentimestamps.v1',
        },
        body: hashBytes,
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      if (resp.ok) {
        const proofBytes = new Uint8Array(await resp.arrayBuffer());
        console.log(`[OTS] Proof received from ${calendar} (${proofBytes.length} bytes)`);
        return proofBytes;
      } else {
        const errText = await resp.text();
        console.log(`[OTS] ${calendar} returned ${resp.status}: ${errText}`);
      }
    } catch (e) {
      console.log(`[OTS] ${calendar} failed:`, e);
    }
  }

  console.error('[OTS] All calendar servers failed');
  return null;
}
