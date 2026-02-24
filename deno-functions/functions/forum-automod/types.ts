export interface AutomodRequest {
  content: string;
  title?: string;
  type: "post" | "topic";
}

export interface AutomodResult {
  allowed: boolean;
  reason?: string;
  message?: string;
  flags?: string[];
  human_flags?: string[];
  auto_hidden?: boolean;
  hidden_reason?: string;
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};
