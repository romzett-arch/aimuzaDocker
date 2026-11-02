// Provider callbacks and record-info have different envelopes. Keep every variant.
export function extractLyricsResults(payload: any): Array<{ key: string; text: string; title: string }> {
  const data = payload?.data;
  const candidates = [data?.response?.data, data?.response?.sunoData, data?.sunoData, data?.data,
    Array.isArray(data) ? data : undefined];
  const items = candidates.find(Array.isArray) ?? (data?.text || data?.lyrics ? [data] : []);
  return items.flatMap((item: any, index: number) => {
    const text = item?.text ?? item?.lyrics;
    // A failed individual variant must never hide another successful one.
    return typeof text === 'string' && text.trim() && item?.status !== 'FAILED'
      ? [{ key: String(index), text: text.trim(), title: typeof item.title === 'string' ? item.title.trim() : '' }]
      : [];
  });
}

export async function recoverLyricsJob(client: any, job: any, apiKey: string) {
  if (!job.provider_task_id) return [];
  const response = await fetch(`https://api.sunoapi.org/api/v1/lyrics/record-info?taskId=${encodeURIComponent(job.provider_task_id)}`, {
    headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(12000),
  });
  if (!response.ok) throw new Error('Не удалось проверить создание текста');
  const payload = await response.json();
  const results = extractLyricsResults(payload);
  if (payload.code === 200 && payload.data?.status === 'SUCCESS' && results.length) {
    const { data, error } = await client.rpc('complete_lyrics_job', { p_job_id: job.id, p_results: JSON.stringify(results) });
    if (error) throw error;
    return data || [];
  }
  if (['FAILED','CREATE_TASK_FAILED','GENERATE_LYRICS_FAILED','SENSITIVE_WORD_ERROR'].includes(payload.data?.status)) {
    const { error } = await client.rpc('fail_lyrics_job', { p_job_id: job.id, p_error: payload.data?.errorMessage || 'Не удалось создать текст' });
    if (error) throw error;
    throw new Error('Не удалось создать текст. Средства возвращены.');
  }
  return [];
}
