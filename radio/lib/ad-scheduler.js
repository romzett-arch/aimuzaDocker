/**
 * Ad Scheduler
 * Sends ad break notifications to clients via WebSocket
 * Clients mute stream and play local ad, then unmute
 */

let tracksSinceLastAd = 0;
const { randomUUID } = require('node:crypto');

async function checkAdBreak(pool, metadataServer, radioConfig) {
  const adConfig = radioConfig?.advertising;
  if (!adConfig) return;
  // enabled: true by default if not set (backward compat)
  if (adConfig.enabled === false) return;

  tracksSinceLastAd++;

  const everyN = adConfig.audio_ad_slot_every_n_tracks || 5;
  if (tracksSinceLastAd < everyN) return;

  tracksSinceLastAd = 0;

  try {
    const { rows } = await pool.query(`
      SELECT id, advertiser_name, promo_text, audio_url, price_paid
      FROM public.radio_ad_placements
      WHERE is_active = true
        AND (starts_at IS NULL OR starts_at <= NOW())
        AND (ends_at IS NULL OR ends_at > NOW())
      -- Weighted random rotation: higher bids get proportionally more traffic,
      -- without permanently starving lower-priced active placements.
      ORDER BY -LN(GREATEST(random(), 0.000000001)) / GREATEST(price_paid::double precision, 1)
      LIMIT 1
    `);

    if (!rows.length) return;

    const ad = rows[0];
    const skipPrice = adConfig.skip_ad_price_rub ?? adConfig.skip_price_rub ?? 5;
    const breakId = randomUUID();
    const duration = adConfig.audio_ad_max_duration_sec || 15;

    await pool.query(
      `INSERT INTO public.radio_ad_breaks(id, ad_id, expires_at)
       VALUES ($1, $2, NOW() + make_interval(secs => $3))`,
      [breakId, ad.id, duration + 60]
    );

    metadataServer.sendAdBreak({
      break_id: breakId,
      ad_id: ad.id,
      advertiser: ad.advertiser_name,
      text: ad.promo_text,
      audio_url: ad.audio_url,
      duration,
      skip_price: skipPrice,
    });

    console.log(`[Ads] Ad break broadcast: ${ad.advertiser_name}`);
  } catch (error) {
    console.error('[Ads] Error:', error.message);
  }
}

function resetAdCounter() {
  tracksSinceLastAd = 0;
}

module.exports = { checkAdBreak, resetAdCounter };
