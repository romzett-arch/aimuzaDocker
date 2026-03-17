export interface GoldPackRequest {
  trackId: string;
  registeredAt?: string;
}

export interface TrackMetadata {
  id: string;
  title: string;
  performer_name: string;
  music_author: string | null;
  lyrics_author: string | null;
  label_name: string | null;
  isrc_code: string | null;
  duration: number;
  genre: { name_ru: string; name: string }[] | null;
  blockchain_hash: string | null;
  cover_url: string | null;
  master_audio_url: string | null;
  certificate_url: string | null;
  created_at: string;
  processing_completed_at: string | null;
  profiles: { username: string | null }[] | null;
}

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
