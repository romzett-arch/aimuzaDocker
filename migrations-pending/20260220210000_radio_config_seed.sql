-- Seed radio_config if table exists
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'radio_config') THEN
    INSERT INTO public.radio_config (key, value)
    VALUES (
      'smart_stream',
      '{"w_quality": 0.35, "w_xp": 0.25, "w_stake": 0.20, "w_freshness": 0.15, "w_discovery": 0.05, "min_quality_score": 2.0, "min_duration_sec": 30, "discovery_boost_days": 14, "discovery_boost_multiplier": 2.5, "max_author_share_percent": 15}'::jsonb
    )
    ON CONFLICT (key) DO NOTHING;
  END IF;
END;
$$;
