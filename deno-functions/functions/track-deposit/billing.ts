interface SupabaseClient {
  from: (table: string) => {
    select: (columns: string) => { eq: (col: string, val: string) => { single: () => Promise<{ data: { balance: number } | null; error: unknown }> } };
    update: (data: { balance: number }) => { eq: (col: string, val: string) => Promise<{ error: unknown }> };
    insert: (data: Record<string, unknown>) => Promise<{ error: unknown }>;
  };
}

export interface BillingResult {
  price: number;
  previousBalance: number;
  newBalance: number;
}

export async function checkAndDeductBalance(
  supabase: SupabaseClient,
  userId: string,
  price: number
): Promise<BillingResult> {
  if (price <= 0) {
    return {
      price,
      previousBalance: 0,
      newBalance: 0,
    };
  }

  const { data: userProfile, error: profileError } = await supabase
    .from("profiles")
    .select("balance")
    .eq("user_id", userId)
    .single();

  console.log(`User balance check: balance=${userProfile?.balance}, price=${price}, error=${(profileError as Error)?.message}`);

  if (!userProfile || userProfile.balance < price) {
    throw new Error(`Недостаточно средств. Требуется: ${price} ₽, баланс: ${userProfile?.balance || 0} ₽`);
  }

  const newBalance = userProfile.balance - price;
  console.log(`Deducting balance: ${userProfile.balance} - ${price} = ${newBalance}`);

  const { error: updateError } = await supabase
    .from("profiles")
    .update({ balance: newBalance })
    .eq("user_id", userId);

  if (updateError) {
    console.error("Balance update error:", updateError);
    throw new Error("Ошибка списания средств");
  }

  console.log(`Balance updated successfully for user ${userId}`);
  return {
    price,
    previousBalance: userProfile.balance,
    newBalance,
  };
}

export async function recordDepositTransaction(
  supabase: SupabaseClient,
  params: {
    userId: string;
    price: number;
    previousBalance: number;
    newBalance: number;
    depositId: string;
    trackId: string;
    trackTitle: string;
    method: string;
  }
): Promise<void> {
  if (params.price <= 0) {
    return;
  }

  const { error } = await supabase.from("balance_transactions").insert({
    user_id: params.userId,
    amount: -params.price,
    balance_before: params.previousBalance,
    balance_after: params.newBalance,
    type: "track_deposit",
    description: `Депонирование трека «${params.trackTitle}» (${params.method})`,
    reference_id: params.depositId,
    reference_type: "track_deposit",
    metadata: {
      track_id: params.trackId,
      track_title: params.trackTitle,
      method: params.method,
    },
  });

  if (error) {
    console.error("Balance transaction insert error:", error);
    throw new Error("Ошибка записи истории списания");
  }
}

export async function refundBalance(
  supabase: SupabaseClient,
  userId: string,
  price: number
): Promise<void> {
  if (price <= 0) {
    return;
  }

  const { data: currentProfile } = await supabase
    .from("profiles")
    .select("balance")
    .eq("user_id", userId)
    .single();

  if (currentProfile) {
    await supabase
      .from("profiles")
      .update({ balance: currentProfile.balance + price })
      .eq("user_id", userId);
  }
}
