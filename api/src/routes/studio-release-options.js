import { pool, setJWTClaims } from '../db.js';

const validUuid = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

export async function readStudioReleaseOptions(req, res, next) {
  if (!validUuid(req.params.trackId)) return res.status(400).json({ error: 'Некорректный идентификатор трека' });
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN READ ONLY');
    await setJWTClaims(client, req.user);
    const track = await client.query('SELECT id FROM public.tracks WHERE id = $1 AND user_id = $2', [req.params.trackId, req.user.id]);
    if (!track.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Трек не найден' });
    }
    const { rows: [row] } = await client.query(
      `SELECT public.get_user_subscription_tier($1) AS tier,
              public.check_deposit_limit($1) AS quota,
              public.promo_release_access($1,$2,false) AS release_promo,
              EXISTS (SELECT 1 FROM jsonb_array_elements(public.get_my_promo_entitlements()) e WHERE e->>'kind' = 'deposit') AS deposit_promo,
              (SELECT price FROM public.get_deposit_method_catalog() WHERE method = 'blockchain' AND available) AS base_price,
              EXISTS (SELECT 1 FROM public.track_deposits WHERE user_id = $1 AND track_id = $2 AND method = 'blockchain' AND status = 'completed') AS deposited`,
      [req.user.id, req.params.trackId],
    );
    if (row.quota?.error || row.base_price == null) throw new Error('Не удалось проверить стоимость депонирования');
    await client.query('COMMIT');
    const tariff = ['creator', 'pro', 'label'].includes(row.tier?.tier_key);
    const promoDeposit = !row.deposited && !row.quota?.is_free && row.deposit_promo && Number(row.base_price) > 0;
    res.json({
      canPrepare: tariff || row.release_promo,
      promoRelease: !tariff && row.release_promo,
      deposit: {
        price: row.deposited || row.quota?.is_free || promoDeposit ? 0 : Number(row.base_price),
        promo: promoDeposit,
        alreadyDeposited: row.deposited,
        freeRemaining: Number(row.quota?.free_remaining || 0),
      },
    });
  } catch (error) {
    if (client) await client.query('ROLLBACK');
    next(error);
  } finally { client?.release(); }
}
