// Callback identity must be verified before parsing payloads or opening a task.
export function constantTimeEqual(left: string, right: string): boolean {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  if (!a.length || a.length !== b.length) return false;
  let different = 0;
  for (let i = 0; i < a.length; i++) different |= a[i] ^ b[i];
  return different === 0;
}

export function isServiceRequest(req: Request): boolean {
  const expected = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return constantTimeEqual(req.headers.get("authorization")?.replace(/^Bearer /, "") || "", expected);
}

export function callbackAuthorized(req: Request, secretName: string): boolean {
  const expected = Deno.env.get(secretName) || "";
  // No development/production fail-open fallback.
  if (expected.length < 32) return false;
  const url = new URL(req.url);
  return [req.headers.get("x-callback-secret"), req.headers.get("authorization")?.replace(/^Bearer /, ""), url.searchParams.get("secret")]
    .some((actual) => !!actual && constantTimeEqual(actual, expected));
}

export function escapeLikeLiteral(value: string): string {
  return value.replace(/[\\%_]/g, "\\$&");
}
