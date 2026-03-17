import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

type MaintenanceStatus = {
  enabled: boolean;
  eta: string | null;
  message: string | null;
  updated_at: string | null;
  whitelisted?: boolean;
};

function toBool(value: string | null | undefined): boolean {
  return (value ?? "").toLowerCase() === "true";
}

const handler = async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const supabaseClient = createClient(supabaseUrl, serviceRoleKey || anonKey);

    let data: Array<{ key: string; value: string; updated_at: string }> | null = null;
    let lastError: unknown = null;

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await supabaseClient
        .from("settings")
        .select("key,value,updated_at")
        .in("key", ["maintenance_mode", "maintenance_eta", "maintenance_message"]);

      if (!result.error) {
        data = result.data as Array<{ key: string; value: string; updated_at: string }> | null;
        lastError = null;
        break;
      }

      lastError = result.error;
      if (attempt < 2) {
        await new Promise((resolve) => setTimeout(resolve, 200 * (attempt + 1)));
      }
    }

    if (lastError) {
      throw lastError;
    }

    const map = new Map<string, { value: string; updated_at: string }>();
    (data ?? []).forEach((row) => map.set(row.key, { value: row.value, updated_at: row.updated_at }));

    const enabled = toBool(map.get("maintenance_mode")?.value);
    const eta = map.get("maintenance_eta")?.value ?? null;
    const message = map.get("maintenance_message")?.value ?? null;
    const updatedAt = map.get("maintenance_mode")?.updated_at ?? null;

    let whitelisted = false;
    if (enabled) {
      const authHeader = req.headers.get("authorization");
      if (authHeader?.startsWith("Bearer ")) {
        const token = authHeader.slice(7);
        try {
          const { data: claims } = await supabaseClient.auth.getUser(token);
          if (claims?.user?.id) {
            const { data: whitelist } = await supabaseClient
              .from("maintenance_whitelist")
              .select("id")
              .eq("user_id", claims.user.id)
              .maybeSingle();

            whitelisted = !!whitelist;
          }
        } catch {
          whitelisted = false;
        }
      }
    }

    const payload: MaintenanceStatus = {
      enabled,
      eta,
      message,
      updated_at: updatedAt,
      whitelisted,
    };

    return new Response(JSON.stringify(payload), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
        "Cache-Control": enabled ? "private, max-age=10" : "private, max-age=15",
      },
    });
  } catch (error) {
    console.error("[maintenance-status] Error:", error);

    return new Response(JSON.stringify({
      enabled: true,
      eta: null,
      message: "Сервис временно недоступен. Попробуйте позже.",
      updated_at: null,
      whitelisted: false,
    }), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
        "Cache-Control": "no-cache",
      },
      status: 200,
    });
  }
};

if (import.meta.main) {
  serve(handler);
}

export default handler;
