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
  lyrics: Record<string, unknown>,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ n'RIS не настроен");
  }

  const response = await fetch(`${apiUrl}/deposits`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      type: "lyrics",
      title: lyrics.title,
      author: lyrics.author_name,
      hash: hash,
      metadata: {
        created_at: lyrics.created_at,
        language: lyrics.language,
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
}

export async function submitToIrma(
  lyrics: Record<string, unknown>,
  hash: string,
  apiKey: string,
  apiUrl: string
): Promise<{ depositId: string; certificateUrl?: string }> {
  if (!apiKey) {
    throw new Error("API ключ IRMA не настроен");
  }

  const response = await fetch(`${apiUrl}/register`, {
    method: "POST",
    headers: {
      "X-API-Key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      work_type: "lyrics",
      title: lyrics.title,
      creators: [{ role: "author", name: lyrics.author_name }],
      content_hash: hash,
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
}
