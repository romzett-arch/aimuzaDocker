import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

type Handler = (req: Request) => Promise<Response> | Response;

const handlers = new Map<string, Handler>();
const enabledFunctions = new Set([
  "robots-txt",
  "sitemap-generator",
  "seo-ai-generate",
  "indexnow-notify",
  "og-renderer",
]);

async function loadHandlers() {
  for await (const entry of Deno.readDir("./functions")) {
    if (!entry.isDirectory) continue;
    if (!enabledFunctions.has(entry.name)) continue;

    try {
      const module = await import(`./functions/${entry.name}/index.ts`);
      const handler = module.default as Handler | undefined;

      if (typeof handler === "function") {
        handlers.set(entry.name, handler);
      } else {
        console.warn(`[deno-functions] Handler not found for ${entry.name}`);
      }
    } catch (error) {
      console.error(`[deno-functions] Failed to load ${entry.name}:`, error);
    }
  }
}

function resolveFunctionName(pathname: string): string | null {
  const segments = pathname.split("/").filter(Boolean);
  if (segments.length === 0) return null;

  if (segments[0] === "functions" && segments[1] === "v1") {
    return segments[2] ?? null;
  }

  return segments[0] ?? null;
}

await loadHandlers();

serve(async (req) => {
  const url = new URL(req.url);
  const functionName = resolveFunctionName(url.pathname);

  if (!functionName) {
    return new Response(JSON.stringify({
      ok: true,
      available: [...handlers.keys()].sort(),
    }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const handler = handlers.get(functionName);
  if (!handler) {
    return new Response(JSON.stringify({
      error: `Function '${functionName}' not available`,
    }), {
      status: 501,
      headers: { "Content-Type": "application/json" },
    });
  }

  return await handler(req);
}, { port: parseInt(Deno.env.get("DENO_PORT") || "8081", 10) });
