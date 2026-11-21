export function createAimuzaClient(origin, secret) {
  return async (action, event, details = {}) => {
    const { reference, ...fields } = details;
    const input = { ...fields, maxId: String(event.userId), standalone: true };
    const headers = { "X-Aimuza-Max-Secret": secret };
    let body;
    if (reference) {
      body = new FormData();
      body.set("input", JSON.stringify(input));
      body.set("reference", reference, "reference");
    } else {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(input);
    }
    const response = await fetch(new URL(`/api/max/internal/${action}`, origin), {
      method: "POST",
      headers,
      body,
      redirect: "error",
      signal: AbortSignal.timeout(action === "identity" ? 5_000 : 145_000),
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
