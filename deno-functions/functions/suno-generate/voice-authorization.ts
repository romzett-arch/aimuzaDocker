export async function hasVoiceAuthorization(
  signature: string | null,
  userId: string,
  trackIds: string[],
  personaId: unknown,
): Promise<boolean> {
  const secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!secret || typeof personaId !== "string" || !signature || !/^[0-9a-f]{64}$/.test(signature)) return false;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );
  const bytes = Uint8Array.from(signature.match(/.{2}/g) ?? [], pair => Number.parseInt(pair, 16));
  return crypto.subtle.verify(
    "HMAC", key, bytes, encoder.encode(JSON.stringify([userId, trackIds, personaId])),
  );
}
