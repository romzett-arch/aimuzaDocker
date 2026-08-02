interface SupabaseClient {
  rpc: (name: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string } | null }>;
}

export interface BillingResult {
  price: number;
  previousBalance: number;
  newBalance: number;
}

export async function beginTrackDeposit(
  supabase: SupabaseClient,
  params: {
    depositId: string;
    trackId: string;
    userId: string;
    method: string;
    fileHash: string;
    metadataHash: string;
    performerName: string;
    lyricsAuthor: string;
  },
): Promise<BillingResult> {
  const { data, error } = await supabase.rpc("begin_track_deposit", {
    p_deposit_id: params.depositId,
    p_track_id: params.trackId,
    p_user_id: params.userId,
    p_method: params.method,
    p_file_hash: params.fileHash,
    p_metadata_hash: params.metadataHash,
    p_performer_name: params.performerName,
    p_lyrics_author: params.lyricsAuthor,
  });
  if (error) throw new Error(error.message || "Не удалось начать депонирование");
  const result = data as { price: number; balance_before: number; balance_after: number };
  return {
    price: Number(result.price || 0),
    previousBalance: Number(result.balance_before || 0),
    newBalance: Number(result.balance_after || 0),
  };
}

export async function failTrackDepositAndRefund(
  supabase: SupabaseClient,
  depositId: string,
  message: string,
): Promise<void> {
  const { error } = await supabase.rpc("fail_track_deposit_and_refund", {
    p_deposit_id: depositId,
    p_error_message: message,
  });
  if (error) throw new Error(error.message || "Не удалось оформить возврат");
}
