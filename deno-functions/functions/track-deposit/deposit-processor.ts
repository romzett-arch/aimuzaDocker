import { generatePdfCertificate } from "./certificate.ts";
import { submitToOpenTimestamps, submitToNris, submitToIrma } from "./external-apis.ts";
import type { AuthorData } from "./types.ts";

type DepositMethod = "internal" | "pdf" | "blockchain" | "nris" | "irma";

interface ProcessResult {
  certificateUrl?: string;
  blockchainTxId?: string;
  externalDepositId?: string;
  externalCertificateUrl?: string;
}

interface SupabaseClient {
  storage: { from: (bucket: string) => { upload: (path: string, blob: Blob, opts: Record<string, string>) => Promise<{ error: unknown }> } };
}

export async function processDepositByMethod(
  method: DepositMethod,
  supabase: SupabaseClient,
  track: Record<string, unknown>,
  fileHash: string,
  depositId: string,
  authorData: AuthorData,
  settingsMap: Map<string, string>
): Promise<ProcessResult> {
  const result: ProcessResult = {};

  switch (method) {
    case "internal":
      result.certificateUrl = await generatePdfCertificate(
        supabase, track, fileHash, depositId, authorData
      );
      break;

    case "pdf":
      result.certificateUrl = await generatePdfCertificate(
        supabase, track, fileHash, depositId, authorData
      );
      break;

    case "blockchain":
      result.blockchainTxId = await submitToOpenTimestamps(fileHash);
      result.certificateUrl = await generatePdfCertificate(
        supabase, track, fileHash, depositId, authorData
      );
      break;

    case "nris": {
      const nrisResult = await submitToNris(
        track,
        fileHash,
        settingsMap.get("nris_api_key") || "",
        settingsMap.get("nris_api_url") || "https://api.nris.ru/v1"
      );
      result.externalDepositId = nrisResult.depositId;
      result.externalCertificateUrl = nrisResult.certificateUrl;
      break;
    }

    case "irma": {
      const irmaResult = await submitToIrma(
        track,
        fileHash,
        settingsMap.get("irma_api_key") || "",
        settingsMap.get("irma_api_url") || "https://api.irma.ru/v1"
      );
      result.externalDepositId = irmaResult.depositId;
      result.externalCertificateUrl = irmaResult.certificateUrl;
      break;
    }
  }

  return result;
}
