interface ReleasePromoClient {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message?: string } | null }>;
}

export async function authorizePromoRelease(
  client: ReleasePromoClient, userId: string, trackId: string, reserve: boolean,
) {
  const { data, error } = await client.rpc("promo_release_access", {
    p_user_id: userId, p_track_id: trackId, p_reserve: reserve,
  });
  if (error) throw new Error(error.message || "Не удалось проверить бонус на релиз-пакет");
  return data === true;
}

export async function resolveReleaseAccess(client: ReleasePromoClient, userId: string, trackId: string, tryPromo: boolean) {
  const { data, error } = await client.rpc("get_user_subscription_tier", { p_user_id: userId });
  if (error) throw new Error(`subscription_check_failed:${error.message}`);
  const tier = (data as { tier_key?: string } | null)?.tier_key;
  if (tier && ["creator", "pro", "label"].includes(tier)) return "tariff";
  return tryPromo && await authorizePromoRelease(client, userId, trackId, false) ? "promo" : null;
}

export function releaseAccessDenied(headers: HeadersInit) {
  return Response.json({
    success: false,
    error: "Релиз-пакет доступен на тарифе «Музыкант» и выше",
    code: "release_package_requires_musician_tier",
  }, { status: 403, headers });
}
