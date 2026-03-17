export async function submitToOpenTimestamps(hash: string): Promise<string> {
  try {
    const response = await fetch("https://a.pool.opentimestamps.org/digest", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: hash,
    });

    if (!response.ok) {
      const fallbackResponse = await fetch("https://b.pool.opentimestamps.org/digest", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: hash,
      });

      if (!fallbackResponse.ok) {
        throw new Error("OpenTimestamps servers unavailable");
      }

      return `ots_pending_${Date.now()}`;
    }

    return `ots_${Date.now()}`;
  } catch (error) {
    console.error("OpenTimestamps error:", error);
    return `ots_pending_${hash.substring(0, 16)}`;
  }
}

export async function submitToNris(
  track: Record<string, unknown>,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ n'RIS не настроен");
  }

  try {
    const genre = track.genre as { name_ru?: string } | undefined;
    const response = await fetch(`${apiUrl}/deposits`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        type: "audio",
        title: track.title,
        author: track.performer_name || (track.profiles as { username?: string })?.username,
        hash: hash,
        metadata: {
          duration: track.duration,
          genre: genre?.name_ru,
          created_at: track.created_at,
          lyrics_author: track.lyrics_author,
          music_author: track.music_author,
        },
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`n'RIS API error: ${error}`);
    }

    const result = await response.json();
    return {
      depositId: result.deposit_id || result.id,
      certificateUrl: result.certificate_url,
    };
  } catch (error) {
    console.error("n'RIS error:", error);
    throw error;
  }
}

export async function submitToIrma(
  track: Record<string, unknown>,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ IRMA не настроен");
  }

  try {
    const genre = track.genre as { name_ru?: string } | undefined;
    const creators: Array<{ role: string; name: string }> = [
      {
        role: "author",
        name: (track.performer_name || (track.profiles as { username?: string })?.username) as string,
      },
    ];
    if (track.music_author) {
      creators.push({ role: "composer", name: track.music_author as string });
    }
    if (track.lyrics_author) {
      creators.push({ role: "lyricist", name: track.lyrics_author as string });
    }

    const response = await fetch(`${apiUrl}/register`, {
      method: "POST",
      headers: {
        "X-API-Key": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        work_type: "music",
        title: track.title,
        creators,
        file_hash: hash,
        additional_info: {
          duration_seconds: track.duration,
          genre: genre?.name_ru,
        },
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`IRMA API error: ${error}`);
    }

    const result = await response.json();
    return {
      depositId: result.registration_id || result.id,
      certificateUrl: result.certificate_url,
    };
  } catch (error) {
    console.error("IRMA error:", error);
    throw error;
  }
}
