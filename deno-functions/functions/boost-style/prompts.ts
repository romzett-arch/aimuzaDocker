import { musicDict } from "./music-dict.ts";

export function translateMusicPrompt(text: string): string {
  let result = text.toLowerCase();
  const sortedEntries = Object.entries(musicDict).sort((a, b) => b[0].length - a[0].length);
  for (const [ru, en] of sortedEntries) {
    const regex = new RegExp(ru, "gi");
    result = result.replace(regex, en);
  }
  result = result.replace(/(\d+)\s*BPM/gi, "$1 BPM");
  result = result.replace(/\s+/g, " ").trim();
  result = result.charAt(0).toUpperCase() + result.slice(1);
  return result;
}
