import { generatePdfCertificate } from "./certificate.ts";
import { submitToOpenTimestamps } from "./external-apis.ts";
import type { AuthorData } from "./types.ts";

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
}

interface SupabaseClient {
  storage: { from: (bucket: string) => { upload: (path: string, blob: Blob, opts: Record<string, string | boolean>) => Promise<{ error: unknown }> } };
}

export async function processDeposit(
  supabase: SupabaseClient,
  track: Record<string, unknown>,
  fileHash: string,
  depositId: string,
  authorData: AuthorData,
): Promise<ProcessResult> {
  const result: ProcessResult = {};

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

  return result;
}
