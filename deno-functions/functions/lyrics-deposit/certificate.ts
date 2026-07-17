export async function generateLyricsCertificate(
  supabase: { storage: { from: (bucket: string) => { upload: (path: string, blob: Blob, opts: Record<string, unknown>) => Promise<{ error: unknown }> } } },
  _lyrics: Record<string, unknown>,
  hash: string,
  depositId: string,
  depositedAt: string,
  signature: string,
  proofStatus: string,
): Promise<string> {
  const evidence = {
    schema: "aimuza-lyrics-evidence-v1",
    issuer: "AIMUZA / ООО «Музыкальный лейбл НОТА-ФЕЯ»",
    evidence_id: depositId,
    evidence_version: "aimuza-lyrics-v1",
    hash_algorithm: "SHA-256",
    content_hash: hash,
    recorded_at: depositedAt,
    proof_status: proofStatus,
    server_signature_algorithm: "HMAC-SHA-256",
    server_signature: signature,
    statement: "Запись подтверждает сохранение цифрового отпечатка версии произведения на указанную дату. Она не создаёт авторское право и сама по себе не устанавливает авторство.",
  };

  const fileName = `lyrics_evidence_${depositId}.json`;
  const bytes = new TextEncoder().encode(JSON.stringify(evidence, null, 2));
  const blob = new Blob([bytes], { type: "application/json;charset=utf-8" });

  const { error: uploadError } = await supabase.storage
    .from("certificates")
    .upload(fileName, blob, {
      contentType: "application/json;charset=utf-8",
      cacheControl: "3600",
      upsert: true,
    });

  if (uploadError) {
    throw new Error("Не удалось сохранить сертификат");
  }

  const BASE_URL = Deno.env.get("BASE_URL") || "https://aimuza.ru";
  return `${BASE_URL}/storage/v1/object/public/certificates/${fileName}`;
}

export async function confirmLyricsCertificate(
  supabase: {
    storage: {
      from: (bucket: string) => {
        download: (path: string) => Promise<{ data: Blob | null; error: unknown }>;
        upload: (path: string, blob: Blob, opts: Record<string, unknown>) => Promise<{ error: unknown }>;
      };
    };
  },
  certificateUrl: string | null,
  confirmedAt: string,
): Promise<void> {
  if (!certificateUrl) return;

  const fileName = decodeURIComponent(new URL(certificateUrl).pathname.split("/").pop() || "");
  if (!fileName) return;

  const bucket = supabase.storage.from("certificates");
  const { data, error } = await bucket.download(fileName);
  if (error || !data) return;

  const evidence = JSON.parse(await data.text()) as Record<string, unknown>;
  evidence.proof_status = "external_confirmed";
  evidence.confirmed_at = confirmedAt;
  evidence.statement = "AIMUZA сохранила цифровую метку этой версии произведения, а независимая сеть подтвердила время её создания. Запись не создаёт авторское право и сама по себе не устанавливает личность автора.";

  const updatedBlob = new Blob(
    [new TextEncoder().encode(JSON.stringify(evidence, null, 2))],
    { type: "application/json;charset=utf-8" },
  );
  await bucket.upload(fileName, updatedBlob, {
    contentType: "application/json;charset=utf-8",
    cacheControl: "3600",
    upsert: true,
  });
}
