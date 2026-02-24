export interface DepositRequest {
  lyricsId: string;
  method: "internal" | "blockchain" | "nris" | "irma";
  authorName?: string;
}
