export interface DepositRequest {
  lyrics_id: string;
  method: "internal" | "blockchain" | "nris" | "irma";
  author_name?: string;
}
