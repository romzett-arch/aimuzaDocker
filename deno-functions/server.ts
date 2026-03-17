import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

type Handler = (req: Request) => Promise<Response> | Response;

const REGISTRY_KEY = "__AIMUZA_FUNCTION_REGISTRY__";
const CURRENT_FUNCTION_KEY = "__AIMUZA_CURRENT_FUNCTION_NAME__";

const handlers = new Map<string, Handler>();
const failedHandlers = new Map<string, string>();

(globalThis as Record<string, unknown>)[REGISTRY_KEY] = handlers;

async function loadHandlers() {
  for await (const entry of Deno.readDir("./functions")) {
    if (!entry.isDirectory) continue;
    if (entry.name.startsWith("_") || entry.name.startsWith(".")) continue;

    (globalThis as Record<string, unknown>)[CURRENT_FUNCTION_KEY] = entry.name;

    try {
      const module = await import(`./functions/${entry.name}/index.ts`);
      const exportedHandler = module.default as Handler | undefined;
      const registeredHandler = handlers.get(entry.name);
      const handler = typeof exportedHandler === "function" ? exportedHandler : registeredHandler;

      if (typeof handler === "function") {
        handlers.set(entry.name, handler);
        console.log(`[deno-functions] Loaded ${entry.name}`);
      } else {
        const message = "Handler not found after import";
        failedHandlers.set(entry.name, message);
        console.warn(`[deno-functions] ${entry.name}: ${message}`);
      }
    } catch (error) {
      const message = error instanceof Error ? `${error.message}\n${error.stack ?? ""}` : String(error);
      failedHandlers.set(entry.name, message);
      console.error(`[deno-functions] Failed to load ${entry.name}:`, error);
    } finally {
      delete (globalThis as Record<string, unknown>)[CURRENT_FUNCTION_KEY];
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
      failed: [...failedHandlers.keys()].sort(),
    }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const handler = handlers.get(functionName);
  if (!handler) {
    return new Response(JSON.stringify({
      error: `Function '${functionName}' not available`,
      available: [...handlers.keys()].sort(),
      loadError: failedHandlers.get(functionName) ?? null,
    }), {
      status: 501,
      headers: { "Content-Type": "application/json" },
    });
  }

  return await handler(req);
}, { port: parseInt(Deno.env.get("DENO_PORT") || "8081", 10) });
