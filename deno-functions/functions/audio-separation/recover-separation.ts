// Recover a missed callback by checking the existing provider task. Never creates
// a new task or charges the user; saving and refunds use the canonical callback.
export async function recoverSeparation({ taskId, apiKey, callbackUrl, fetcher = fetch }: {
  taskId: string; apiKey: string; callbackUrl: string; fetcher?: typeof fetch;
}) {
  const response = await fetcher(`https://apibox.erweima.ai/api/v1/vocal-removal/record-info?taskId=${encodeURIComponent(taskId)}`, {
    headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error('Не удалось проверить разделение');
  const body = await response.json();
  if (Number(body.code) !== 200) throw new Error('Сервис не вернул состояние разделения');
  const data = body.data;
  const status = data?.successFlag;
  const result = data?.response;
  let payload;
  if (status === 'SUCCESS' && result?.vocalUrl && result?.instrumentalUrl) {
    payload = { code: 200, data: { task_id: taskId, vocal_removal_info: {
      vocal_url: result.vocalUrl, instrumental_url: result.instrumentalUrl, origin_url: result.originUrl || '',
    } } };
  } else if (['CREATE_TASK_FAILED', 'GENERATE_AUDIO_FAILED'].includes(status)) {
    payload = { code: 500, msg: 'Сервис не смог разделить трек', data: { task_id: taskId } };
  } else {
    return; // pending, unknown, or incomplete result: leave the existing job intact
  }
  const saved = await fetcher(callbackUrl, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    signal: AbortSignal.timeout(90_000),
  });
  if (!saved.ok) throw new Error('Не удалось сохранить результат разделения');
}
