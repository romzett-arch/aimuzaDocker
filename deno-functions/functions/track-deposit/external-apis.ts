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

      if (!response.ok) continue;
      const buffer = await response.arrayBuffer();
      if (buffer.byteLength === 0) continue;

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
