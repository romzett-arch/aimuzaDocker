import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

interface ReleaseMetadata {
  artistName: string;
  authorName: string;
  genreName: string;
  publisherName: string;
  cabinetId: string;
  metadata: Record<string, string>;
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function sanitizeBaseName(value: string): string {
  return (value || "release-track")
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120) || "release-track";
}

export function buildReleaseMetadata(track: {
  id: string;
  user_id: string;
  title: string | null;
  performer_name?: string | null;
  author_name?: string | null;
  music_author?: string | null;
  lyrics_author?: string | null;
  genre_name?: string | null;
  label_name?: string | null;
  profile?: {
    username?: string | null;
    display_name?: string | null;
    short_id?: string | null;
  } | null;
}): ReleaseMetadata {
  const artistName =
    track.performer_name?.trim()
    || track.profile?.display_name?.trim()
    || track.profile?.username?.trim()
    || "AIMuza Artist";
  const authorName =
    track.author_name?.trim()
    || track.music_author?.trim()
    || track.lyrics_author?.trim()
    || artistName;
  const genreName = track.genre_name?.trim() || "Без жанра";

  const publisherName = track.label_name?.trim() || "AIMuza";
  const cabinetId = track.profile?.short_id?.trim() || track.user_id;
  const title = track.title || "Без названия";

  return {
    artistName,
    authorName,
    genreName,
    publisherName,
    cabinetId,
    metadata: {
      title,
      artist: artistName,
      composer: authorName,
      genre: genreName,
      album: "AIMuza Release Package",
      publisher: publisherName,
      comment: `Prepared for release on aimuza.ru | Cabinet ID: ${cabinetId} | Track ID: ${track.id} | Author: ${authorName}`,
      copyright: `© ${new Date().getFullYear()} ${authorName} performed by ${artistName} via ${publisherName}`,
      TXXX_AIMUZA_TRACK_ID: track.id,
      TXXX_AIMUZA_USER_ID: track.user_id,
      TXXX_AIMUZA_CABINET_ID: cabinetId,
      TXXX_AIMUZA_ARTIST: artistName,
      TXXX_AIMUZA_AUTHOR: authorName,
      TXXX_AIMUZA_PUBLISHER: publisherName,
      TXXX_AIMUZA_RELEASE_PACKAGE: "true",
      TXXX_AIMUZA_WEBSITE: "aimuza.ru",
    },
  };
}

export async function loadProfileIdentity(
  supabase: SupabaseClient,
  userId: string,
): Promise<{ username: string | null; display_name: string | null; short_id: string | null }> {
  const { data } = await supabase
    .from("profiles")
    .select("username")
    .eq("user_id", userId)
    .maybeSingle();

  return {
    username: data?.username ?? null,
    display_name: null,
    short_id: null,
  };
}

export function buildReleaseInfoText(input: {
  title: string;
  artistName: string;
  authorName: string;
  genreName: string;
  publisherName: string;
  includeDeposit: boolean;
  promptText?: string | null;
  lyricsText?: string | null;
  includeLyricsBlock: boolean;
}): string {
  const sections = [
    "AIMuza Release Package",
    "",
    `Title: ${input.title}`,
    `Performer: ${input.artistName}`,
    `Author: ${input.authorName}`,
    `Genre: ${input.genreName}`,
    `Publisher: ${input.publisherName}`,
    `Deposit included: ${input.includeDeposit ? "yes" : "no"}`,
    `Generated at: ${new Date().toISOString()}`,
  ];

  if (input.includeLyricsBlock) {
    sections.push("", "Lyrics:");
    sections.push(input.lyricsText?.trim() || "Текст отсутствует");
    sections.push("", "Prompt:");
    sections.push(input.promptText?.trim() || "Промт отсутствует");
  }

  return sections.join("\n");
}

export function buildGenreText(input: {
  genreName: string;
  hasLyrics: boolean;
  lyricsText?: string | null;
  promptText?: string | null;
}): string {
  const sections = [
    input.genreName,
    input.hasLyrics ? "с текстом" : "без текста",
  ];

  if (input.hasLyrics) {
    sections.push("", "Текст трека:");
    sections.push(input.lyricsText?.trim() || "Текст отсутствует");
    sections.push("", "Промт:");
    sections.push(input.promptText?.trim() || "Промт отсутствует");
  }

  return `${sections.join("\n")}\n`;
}
