export async function requestMaxBroadcast(owner, input) {
  const secret = process.env.MAX_INTERNAL_SECRET?.trim();
  if (!secret || secret.length < 32) return [503, { code: 'MAX_BOT_UNAVAILABLE' }];

  try {
    const response = await fetch('http://max-bot:3215/internal/admin/broadcast', {
      method: 'POST',
      headers: { 'X-Aimuza-Max-Secret': secret, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...input, owner }),
      redirect: 'error',
      signal: AbortSignal.timeout(12_000),
    });
    if ([200, 400, 404, 409].includes(response.status)) return [response.status, await response.json()];
  } catch {
    // Повтор запроса с тем же ID возвращает исходную рассылку.
  }
  return [503, { code: 'MAX_BOT_UNAVAILABLE' }];
}
