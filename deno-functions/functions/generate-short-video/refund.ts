import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export async function refundUser(
  supabase: SupabaseClient,
  userId: string,
  price: number,
): Promise<void> {
  const { data: currentProfile } = await supabase
    .from("profiles")
    .select("balance")
    .eq("user_id", userId)
    .single();

  await supabase
    .from("profiles")
    .update({ balance: (currentProfile?.balance || 0) + price })
    .eq("user_id", userId);
}
