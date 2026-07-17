import OpenTimestamps from "npm:opentimestamps@0.4.9";

export interface OpenTimestampsUpgradeResult {
  confirmed: boolean;
  changed: boolean;
  proofBase64: string;
}

function hexToBytes(value: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/i.test(value)) {
    throw new Error("Некорректный цифровой отпечаток");
  }
  return Uint8Array.from(value.match(/.{2}/g) || [], (byte) => parseInt(byte, 16));
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function bytesToBase64(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export async function submitToOpenTimestamps(hash: string): Promise<{ id: string; proofBase64: string }> {
  const digest = Uint8Array.from(hash.match(/.{2}/g) || [], (byte) => parseInt(byte, 16));
  let lastError = "OpenTimestamps servers unavailable";

  for (const host of ["https://a.pool.opentimestamps.org", "https://b.pool.opentimestamps.org"]) {
    try {
      const response = await fetch(`${host}/digest`, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: digest,
      });
      if (!response.ok) {
        lastError = `OpenTimestamps HTTP ${response.status}`;
        continue;
      }
      const proof = new Uint8Array(await response.arrayBuffer());
      let binary = "";
      for (const byte of proof) binary += String.fromCharCode(byte);
      return {
        id: `ots-pending-${hash.substring(0, 16)}`,
        proofBase64: btoa(binary),
      };
    } catch (error) {
      lastError = error instanceof Error ? error.message : lastError;
    }
  }
  throw new Error(`Не удалось получить доказательство OpenTimestamps: ${lastError}`);
}

export async function upgradeOpenTimestamps(
  hash: string,
  proofBase64: string,
): Promise<OpenTimestampsUpgradeResult> {
  const hashBytes = hexToBytes(hash);
  const proofBytes = base64ToBytes(proofBase64);

  // Calendar /digest returns the timestamp tree without the detached-file header.
  // Recreate the detached proof so the official client can request its upgrade.
  const context = new OpenTimestamps.Context.StreamDeserialization(Array.from(proofBytes));
  const timestamp = OpenTimestamps.Timestamp.deserialize(context, Array.from(hashBytes));
  const detached = OpenTimestamps.DetachedTimestampFile.fromHash(
    new OpenTimestamps.Ops.OpSHA256(),
    hashBytes,
  );
  detached.timestamp = timestamp;

  const changed = await OpenTimestamps.upgrade(detached, { timeout: 10_000 });
  const confirmed = detached.timestamp.isTimestampComplete();

  const output = new OpenTimestamps.Context.StreamSerialization();
  detached.timestamp.serialize(output);

  return {
    confirmed,
    changed,
    proofBase64: bytesToBase64(output.getOutput()),
  };
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
