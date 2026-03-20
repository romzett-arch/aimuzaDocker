export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

export const TIMEWEB_AGENT_ACCESS_ID = "e046a9e4-43f6-47bc-a39f-8a9de8778d02";

export interface SunoCallbackPayload {
  code?: number;
  msg?: string;
  data?: {
    callbackType?: string;
    task_id?: string;
    taskId?: string;
    fail_reason?: string;
    data?: SunoTrackData[];
  };
}

export interface SunoTrackData {
  id?: string;
  audio_url?: string;
  audioUrl?: string;
  source_audio_url?: string;
  sourceAudioUrl?: string;
  stream_audio_url?: string;
  streamAudioUrl?: string;
  source_stream_audio_url?: string;
  sourceStreamAudioUrl?: string;
  image_url?: string;
  imageUrl?: string;
  source_image_url?: string;
  sourceImageUrl?: string;
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
  audio_url?: string | null;
  suno_audio_id?: string | null;
}

export interface TrackToFail {
  id: string;
  user_id: string;
}
