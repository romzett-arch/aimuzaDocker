function normalizeFetchUrl(sourceUrl: string): string {
  const fallbackOrigin = Deno.env.get("SUPABASE_URL") || Deno.env.get("BASE_URL") || "http://api:3000";
  let parsed: URL;

  try {
    parsed = new URL(sourceUrl);
  } catch {
    return sourceUrl;
  }

  if (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1") {
    const internalOrigin = new URL(fallbackOrigin);
    parsed.protocol = internalOrigin.protocol;
    parsed.hostname = internalOrigin.hostname;
    parsed.port = internalOrigin.port;
  }

  return parsed.toString();
}

export async function generateHash(data: string): Promise<string> {
  const encoder = new TextEncoder();
  const dataBuffer = encoder.encode(data);
  const hashBuffer = await crypto.subtle.digest("SHA-256", dataBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

export async function getAudioHash(audioUrl: string): Promise<string> {
  try {
    const fetchUrl = normalizeFetchUrl(audioUrl);
    if (fetchUrl !== audioUrl) {
      console.log(`Rewriting audio URL for container access: ${audioUrl} -> ${fetchUrl}`);
    }

    const response = await fetch(fetchUrl);
    const buffer = await response.arrayBuffer();
    const hashBuffer = await crypto.subtle.digest("SHA-256", buffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
  } catch (error) {
    console.error("Error fetching audio for hash:", error);
    throw new Error("Не удалось получить аудиофайл для хеширования");
  }
}
