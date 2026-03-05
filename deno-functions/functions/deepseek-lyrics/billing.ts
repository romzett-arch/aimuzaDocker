import { MODE_SERVICE_MAP } from "./types.ts";
import type { Mode } from "./types.ts";

export type BillingResult = {
  price: number;
  newBalance: number;
  previousBalance: number;
  error?: string;
};

export async function checkAndDeductBalance(
  supabase: { from: (t: string) => unknown },
  userId: string,
  mode: Mode,
  skipBilling: boolean
): Promise<BillingResult> {
  const serviceName = MODE_SERVICE_MAP[mode] || "generate_lyrics";
  const { data: service } = await supabase
    .from("addon_services")
    .select("price_rub")
    .eq("name", serviceName)
    .maybeSingle();

  const price = skipBilling ? 0 : (service?.price_rub ?? 5);

  const { data: profile } = await supabase
    .from("profiles")
    .select("balance")
    .eq("user_id", userId)
    .maybeSingle();

  const previousBalance = profile?.balance || 0;

  if (!skipBilling && (!profile || previousBalance < price)) {
    return { price, newBalance: previousBalance, previousBalance, error: "Недостаточно средств на балансе" };
  }

  const newBalance = skipBilling ? previousBalance : previousBalance - price;

  if (!skipBilling) {
    const { error: balanceError } = await supabase
      .from("profiles")
      .update({ balance: newBalance })
      .eq("user_id", userId);

    if (balanceError) {
      return { price, newBalance: previousBalance, previousBalance, error: "Ошибка списания баланса" };
    }

    await supabase.from("balance_transactions").insert({
      user_id: userId,
      amount: -price,
      balance_after: newBalance,
      type: "lyrics_gen",
      description: `Генерация текста (${mode})`,
      metadata: { mode },
    });
  }

  return { price, newBalance, previousBalance };
}
