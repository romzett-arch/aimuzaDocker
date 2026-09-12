-- Remove owner-generated promotion events recorded before owner preview protection.
WITH owner_counts AS (
  SELECT
    e.promotion_id,
    COUNT(*) FILTER (WHERE e.event_type = 'impression')::INTEGER AS impressions,
    COUNT(*) FILTER (WHERE e.event_type IN ('open', 'play'))::INTEGER AS clicks,
    COUNT(*) FILTER (WHERE e.event_type = 'impression' AND e.surface = 'shelf')::INTEGER AS shelf_impressions,
    COUNT(*) FILTER (WHERE e.event_type = 'impression' AND e.surface = 'feed')::INTEGER AS feed_impressions,
    COUNT(*) FILTER (WHERE e.event_type = 'impression' AND e.surface = 'radio')::INTEGER AS radio_impressions,
    COUNT(*) FILTER (WHERE e.event_type = 'open')::INTEGER AS opens,
    COUNT(*) FILTER (WHERE e.event_type = 'play')::INTEGER AS plays
  FROM public.track_promotion_events e
  JOIN public.track_promotions tp ON tp.id = e.promotion_id
  WHERE e.user_id = tp.user_id
  GROUP BY e.promotion_id
), adjusted AS (
  UPDATE public.track_promotions tp
  SET
    impressions_count = GREATEST(0, COALESCE(tp.impressions_count, 0) - c.impressions),
    clicks_count = GREATEST(0, COALESCE(tp.clicks_count, 0) - c.clicks),
    shelf_impressions_count = GREATEST(0, COALESCE(tp.shelf_impressions_count, 0) - c.shelf_impressions),
    feed_impressions_count = GREATEST(0, COALESCE(tp.feed_impressions_count, 0) - c.feed_impressions),
    radio_impressions_count = GREATEST(0, COALESCE(tp.radio_impressions_count, 0) - c.radio_impressions),
    opens_count = GREATEST(0, COALESCE(tp.opens_count, 0) - c.opens),
    plays_count = GREATEST(0, COALESCE(tp.plays_count, 0) - c.plays)
  FROM owner_counts c
  WHERE tp.id = c.promotion_id
  RETURNING tp.id
)
DELETE FROM public.track_promotion_events e
USING public.track_promotions tp
WHERE e.promotion_id = tp.id
  AND e.user_id = tp.user_id;
