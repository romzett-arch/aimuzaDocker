import { generatePdfCertificate } from "./certificate.ts";
import { submitToOpenTimestamps, submitToNris, submitToIrma } from "./external-apis.ts";
import type { AuthorData } from "./types.ts";

type DepositMethod = "internal" | "pdf" | "blockchain" | "nris" | "irma";

interface ProcessResult {
  certificateUrl?: string;
  pdfUrl?: string;
  registryUrl?: string;
  certificateHtmlHash?: string;
  certificatePdfHash?: string;
  certificateGeneratedAt?: string;
  blockchainTxId?: string;
  blockchainProofPath?: string;
  blockchainProofUrl?: string;
  blockchainProofStatus?: "pending";
  blockchainSubmittedAt?: string;
  externalDepositId?: string;
  externalCertificateUrl?: string;
}

interface SupabaseClient {
  storage: { from: (bucket: string) => { upload: (path: string, blob: Blob, opts: Record<string, string | boolean>) => Promise<{ error: unknown }> } };
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
      Object.assign(result, await generatePdfCertificate(
        supabase, track, fileHash, depositId, authorData
      ));
      break;

    case "pdf":
      Object.assign(result, await generatePdfCertificate(
        supabase, track, fileHash, depositId, authorData
      ));
      break;

    case "blockchain":
      Object.assign(result, await submitToOpenTimestamps(supabase, fileHash, depositId));
      Object.assign(result, await generatePdfCertificate(
        supabase,
        track,
        fileHash,
        depositId,
        authorData,
        {
          blockchainProofStatus: result.blockchainProofStatus,
          blockchainProofUrl: result.blockchainProofUrl,
          blockchainSubmittedAt: result.blockchainSubmittedAt,
          blockchainTxId: result.blockchainTxId,
        },
      ));
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
