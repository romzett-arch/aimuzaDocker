import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const supabaseClient = createClient(
      supabaseUrl,
      serviceRoleKey || anonKey
    );

    // Read settings keys with retry for transient connection resets
    let data: any = null;
    let lastError: any = null;
    for (let attempt = 0; attempt < 3; attempt++) {
      const res = await supabaseClient
        .from("settings")
        .select("key,value,updated_at")
        .in("key", ["maintenance_mode", "maintenance_eta", "maintenance_message"]);
      if (!res.error) { data = res.data; lastError = null; break; }
      lastError = res.error;
      if (attempt < 2) await new Promise(r => setTimeout(r, 200 * (attempt + 1)));
    }
    if (lastError) throw lastError;

    const map = new Map<string, { value: string; updated_at: string }>();
    (data ?? []).forEach((row: any) => map.set(row.key, { value: row.value, updated_at: row.updated_at }));

    const enabled = toBool(map.get("maintenance_mode")?.value);
    const eta = map.get("maintenance_eta")?.value ?? null;
    const message = map.get("maintenance_message")?.value ?? null;
    const updatedAt = map.get("maintenance_mode")?.updated_at ?? null;

    // Check if user is whitelisted (only if maintenance is enabled)
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
          // Ignore auth errors, just don't whitelist
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
        // If enabled and ETA provided, clients can re-check later; fallback to 5 min.
        "Cache-Control": enabled ? "public, max-age=60" : "public, max-age=30",
      },
    });
  } catch (err) {
    console.error("maintenance-status error:", err);
    const message = err instanceof Error ? err.message : "Unknown error";
    return new Response(JSON.stringify({ enabled: false, error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
