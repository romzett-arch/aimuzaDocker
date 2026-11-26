import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

type TopupOffer = {
  payment_id: string;
  bonus_amount: number;
  bonus_percent: number;
  bonus_expires_at: string;
};

const promoErrors: Record<string, string> = {
  promo_invalid: "Проверьте написание бонус-кода.",
  promo_not_for_topup: "Этот бонус-код можно активировать при регистрации или в профиле.",
  promo_unavailable: "Этот бонус-код сейчас недоступен.",
  promo_already_activated: "Вы уже использовали бонус-код этой кампании.",
  promo_limit_reached: "Доступные активации бонус-кода закончились или заняты ожидающими платежами.",
  promo_budget_exhausted: "Остатка бюджета кампании недостаточно для этого бонуса.",
  promo_attempt_limit: "Слишком много попыток. Попробуйте через несколько минут.",
};

export async function createTopupPayment(client: SupabaseClient, input: {
  userId: string;
  amount: number;
  system: "robokassa" | "yookassa";
  description: string;
  externalId?: string;
  method?: string;
  promoCode: unknown;
}): Promise<{ paymentId: string; offer?: TopupOffer } | { error: string; status: number }> {
  const { promoCode } = input;
  if (promoCode != null && typeof promoCode !== "string") return { error: promoErrors.promo_invalid, status: 400 };
  if (promoCode?.trim()) {
    const { data, error } = await client.rpc("create_promo_topup_payment", {
      p_user: input.userId, p_amount: input.amount, p_system: input.system,
      p_description: input.description, p_external_id: input.externalId ?? null,
      p_method: input.method ?? null, p_code: promoCode.trim(),
    });
    if (data?.error) return { error: promoErrors[data.error] || "Не удалось применить бонус-код.", status: 400 };
    if (!error && data?.payment_id) return { paymentId: data.payment_id, offer: data as TopupOffer };
    console.error("Promo top-up creation failed", error?.code);
    return { error: "Ошибка создания платежа", status: 500 };
  }

  const { data, error } = await client.from("payments").insert({
    user_id: input.userId, amount: input.amount, currency: "RUB", status: "pending",
    payment_system: input.system, description: input.description,
    ...(input.externalId && { external_id: input.externalId }),
    ...(input.method && { metadata: { method: input.method } }),
  }).select("id").single();
  if (!error && data?.id) return { paymentId: data.id };
  console.error("Top-up creation failed", error?.code);
  return { error: "Ошибка создания платежа", status: 500 };
}
