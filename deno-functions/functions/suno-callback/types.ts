export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

export const TIMEWEB_AGENT_ACCESS_ID = "0846d064-4950-4d79-a54c-62ba315cdb34";

export interface SunoCallbackPayload {
  code?: number;
  msg?: string;
  data?: {
    callbackType?: string;
    task_id?: string;
    fail_reason?: string;
    data?: SunoTrackData[];
  };
}

export interface SunoTrackData {
  id?: string;
  audio_url?: string;
  source_audio_url?: string;
  stream_audio_url?: string;
  image_url?: string;
  source_image_url?: string;
  duration?: number;
  title?: string;
}

export interface MatchedTrack {
  id: string;
  title: string | null;
  description: string | null;
  lyrics: string | null;
  user_id: string;
  status: string;
}

export interface TrackToFail {
  id: string;
  user_id: string;
}
