interface GenerationClient {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message?: string } | null }>;
}

interface GenerationDispatch {
  userId: string;
  trackIds: string[];
  operation: "generate" | "upload_cover";
  endpoint: string;
  apiKey: string;
  payload: Record<string, unknown>;
}

export async function dispatchAuthorizedGeneration(
  client: GenerationClient, { userId, trackIds, operation, endpoint, apiKey, payload }: GenerationDispatch,
  send: typeof fetch = fetch,
): Promise<Response | null> {
  const { data, error } = await client.rpc("claim_suno_generation", {
    p_user_id: userId, p_track_ids: trackIds, p_operation: operation,
  });
  if (error) throw error;
  if (data !== true) return null;

  return send(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + apiKey },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(30_000),
  });
}
