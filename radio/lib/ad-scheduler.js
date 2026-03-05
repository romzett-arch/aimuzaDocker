/**
 * Ad Scheduler
 * Sends ad break notifications to clients via WebSocket
 * Clients mute stream and play local ad, then unmute
 */

let tracksSinceLastAd = 0;

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
        AND (ends_at IS NULL OR ends_at > NOW())
      ORDER BY price_paid DESC
      LIMIT 1
    `);

    if (!rows.length) return;

    const ad = rows[0];
    const skipPrice = adConfig.skip_ad_price_rub ?? adConfig.skip_price_rub ?? 5;

    metadataServer.sendAdBreak({
      ad_id: ad.id,
      advertiser: ad.advertiser_name,
      text: ad.promo_text,
      audio_url: ad.audio_url,
      duration: adConfig.audio_ad_max_duration_sec || 15,
      skip_price: skipPrice,
    });

    await pool.query(
      'UPDATE public.radio_ad_placements SET impressions = impressions + 1 WHERE id = $1',
      [ad.id]
    );

    console.log(`[Ads] Ad break: ${ad.advertiser_name}`);
  } catch (error) {
    console.error('[Ads] Error:', error.message);
  }
}

function resetAdCounter() {
  tracksSinceLastAd = 0;
}

module.exports = { checkAdBreak, resetAdCounter };
