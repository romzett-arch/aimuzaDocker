interface SupabaseClient {
  from: (table: string) => {
    select: (columns: string) => { eq: (col: string, val: string) => { single: () => Promise<{ data: { balance: number } | null; error: unknown }> } };
    update: (data: { balance: number }) => { eq: (col: string, val: string) => Promise<{ error: unknown }> };
  };
}

export async function checkAndDeductBalance(
  supabase: SupabaseClient,
  userId: string,
  price: number
): Promise<void> {
  if (price <= 0) {
    return;
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
