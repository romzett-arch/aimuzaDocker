export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

export const TIMEWEB_AGENT_ACCESS_ID =
  Deno.env.get("TIMEWEB_AGENT_ID") || "df42cd86-5e91-459e-a95a-a7befb625292";
