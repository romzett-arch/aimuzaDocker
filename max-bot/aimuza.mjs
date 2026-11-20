export function createAimuzaClient(origin, secret) {
  return async (action, event, details = {}) => {
    const response = await fetch(new URL(`/api/max/internal/${action}`, origin), {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Aimuza-Max-Secret": secret },
      body: JSON.stringify({ ...details, maxId: String(event.userId), standalone: true }),
      redirect: "error",
      signal: AbortSignal.timeout(145_000),
    });
    if (!response.ok) {
      const data = await response.json().catch(() => null);
      const failure = new Error(data?.code ?? "AIMUZA_UNAVAILABLE");
      failure.status = response.status;
      throw failure;
    }
    if (action === "media") return response.blob();
    return response.json();
  };
}
