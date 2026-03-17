interface StorageUploader {
  storage: {
    from: (bucket: string) => {
      upload: (
        path: string,
        body: Blob,
        options: Record<string, string | boolean>,
      ) => Promise<{ error: unknown }>;
    };
  };
}

export interface OpenTimestampsResult {
  blockchainTxId: string;
  blockchainProofPath: string;
  blockchainProofUrl: string;
  blockchainProofStatus: "pending";
  blockchainSubmittedAt: string;
}

const OTS_CALENDARS = [
  "https://a.pool.opentimestamps.org/digest",
  "https://b.pool.opentimestamps.org/digest",
];

function getPublicStorageUrl(path: string): string {
  const baseUrl = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  return `${baseUrl}/storage/v1/object/public/certificates/${path}`;
}

export async function submitToOpenTimestamps(
  supabase: StorageUploader,
  hash: string,
  depositId: string,
): Promise<OpenTimestampsResult> {
  let proofBytes: Uint8Array | null = null;

  for (const calendarUrl of OTS_CALENDARS) {
    try {
      const response = await fetch(calendarUrl, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: hash,
      });

      if (!response.ok) {
        continue;
      }

      const buffer = await response.arrayBuffer();
      if (buffer.byteLength === 0) {
        continue;
      }

      proofBytes = new Uint8Array(buffer);
      break;
    } catch (error) {
      console.error("OpenTimestamps calendar error:", calendarUrl, error);
    }
  }

  if (!proofBytes) {
    throw new Error("Не удалось получить OpenTimestamps proof");
  }

  const proofPath = `proofs/certificate_${depositId}.ots`;
  const { error: uploadError } = await supabase.storage
    .from("certificates")
    .upload(
      proofPath,
      new Blob([proofBytes], { type: "application/octet-stream" }),
      {
        contentType: "application/octet-stream",
        cacheControl: "31536000",
        upsert: true,
      },
    );

  if (uploadError) {
    console.error("OpenTimestamps proof upload error:", uploadError);
    throw new Error("Не удалось сохранить OpenTimestamps proof");
  }

  return {
    blockchainTxId: `ots:${hash.substring(0, 16)}`,
    blockchainProofPath: proofPath,
    blockchainProofUrl: getPublicStorageUrl(proofPath),
    blockchainProofStatus: "pending",
    blockchainSubmittedAt: new Date().toISOString(),
  };
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
