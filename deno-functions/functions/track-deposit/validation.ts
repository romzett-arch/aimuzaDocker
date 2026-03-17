import type { AuthorData } from "./types.ts";

interface TrackWithAuthors {
  performer_name?: string;
  music_author?: string;
  lyrics_author?: string;
  [key: string]: unknown;
}

export function getEffectiveAuthorData(
  authorData: AuthorData | undefined,
  track: TrackWithAuthors,
  username: string
): { performer_name: string; music_author: string; lyrics_author: string } {
  return {
    performer_name: authorData?.performer_name || track?.performer_name || username,
    music_author: authorData?.music_author || track?.music_author || "",
    lyrics_author: authorData?.lyrics_author || track?.lyrics_author || "",
  };
}

export function validateTrack(track: unknown, trackId: string): asserts track is Record<string, unknown> & { audio_url: string } {
  if (!track) {
    throw new Error("Трек не найден или не принадлежит вам");
  }
  const t = track as Record<string, unknown>;
  if (!t.audio_url) {
    throw new Error("Трек не имеет аудиофайла");
  }
}
