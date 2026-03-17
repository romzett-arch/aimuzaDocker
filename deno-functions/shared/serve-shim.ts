import { serve as stdServe } from "https://deno.land/std@0.168.0/http/server.ts?std-bypass";

type Handler = (req: Request) => Promise<Response> | Response;

const REGISTRY_KEY = "__AIMUZA_FUNCTION_REGISTRY__";
const CURRENT_FUNCTION_KEY = "__AIMUZA_CURRENT_FUNCTION_NAME__";

export function serve(handler: Handler, options?: Parameters<typeof stdServe>[1]) {
  const registry = (globalThis as Record<string, unknown>)[REGISTRY_KEY];
  const currentFunctionName = (globalThis as Record<string, unknown>)[CURRENT_FUNCTION_KEY];

  if (registry instanceof Map && typeof currentFunctionName === "string" && currentFunctionName.length > 0) {
    registry.set(currentFunctionName, handler);
    return Promise.resolve();
  }

  return stdServe(handler, options);
}
