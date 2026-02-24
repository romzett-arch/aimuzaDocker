export async function callVps(
  url: string,
  endpoint: string,
  payload: Record<string, unknown>,
  timeoutMs = 30000,
  headers?: Record<string, string>,
): Promise<any | null> {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
    const reqHeaders: Record<string, string> = { 'Content-Type': 'application/json', ...headers };

    const resp = await fetch(`${url}${endpoint}`, {
      method: 'POST',
      headers: reqHeaders,
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    clearTimeout(timeoutId);

    if (!resp.ok) {
      const errText = await resp.text();
      console.error(`[VPS] ${endpoint} error ${resp.status}: ${errText}`);
      return null;
    }
    return await resp.json();
  } catch (e) {
    console.error(`[VPS] ${endpoint} failed:`, e);
    return null;
  }
}

export function parseAnalysis(raw: any) {
  const audioStream = raw.streams?.find((s: any) => s.codec_type === 'audio') || {};
  const highFreqCutoff = raw.spectrum?.high_freq_cutoff || 20000;
  const upscaleDetected = highFreqCutoff < 16000;
  const originalLufs = raw.lufs?.integrated ?? -16;
  const peakDb = raw.lufs?.true_peak ?? -1;
  const dynamicRange = raw.lufs?.range ?? 8;
  const sampleRate = parseInt(audioStream.sample_rate) || 44100;
  const bitDepth = audioStream.bits_per_sample || 24;
  const channels = audioStream.channels || 2;
  const duration = parseFloat(raw.format?.duration) || 0;
  const format = raw.format?.format_name || 'unknown';

  let qualityScore = 10;
  if (upscaleDetected) qualityScore -= 3;
  if (sampleRate < 44100) qualityScore -= 2;
  if (bitDepth < 16) qualityScore -= 2;
  if (originalLufs > -8) qualityScore -= 1;
  qualityScore = Math.max(1, Math.min(10, qualityScore));

  return {
    highFreqCutoff, upscaleDetected, originalLufs, peakDb, dynamicRange,
    sampleRate, bitDepth, channels, duration, format, qualityScore,
    masterQuality: bitDepth >= 24 && ['wav', 'flac', 'aiff'].includes(format),
  };
}
