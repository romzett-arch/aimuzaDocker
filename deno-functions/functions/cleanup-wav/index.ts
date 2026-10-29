import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// Compatibility for the old service-only cron: the API worker is the sole cleaner.
serve(async req => {
  const headers = { "Content-Type": "application/json" };
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key || req.headers.get("Authorization") !== `Bearer ${key}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers });
  }
  try {
    const response = await fetch(`${Deno.env.get("SUPABASE_URL")}/internal/media-cleanup`, {
      method: "POST", headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(10000),
    });
    return new Response(await response.text(), { status: response.status, headers });
  } catch {
    return new Response(JSON.stringify({ error: "Cleanup worker unavailable" }), { status: 503, headers });
  }
});
