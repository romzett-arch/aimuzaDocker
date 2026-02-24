export interface AuthorData {
  performer_name: string;
  music_author: string;
  lyrics_author: string;
}

export interface DepositRequest {
  trackId: string;
  method: "internal" | "pdf" | "blockchain" | "nris" | "irma";
  authorData?: AuthorData;
}

export interface DepositError extends Error {
  message: string;
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};
