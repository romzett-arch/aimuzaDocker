-- =====================================================
-- CREATOR ECONOMY & ATTRIBUTION SHARE SYSTEM
-- Единая экономическая модель: Attribution Pool, Quality Gate,
-- Creator Earnings, Economy Health Metrics
-- =====================================================

-- ─── 1. Attribution Pool — ежемесячный фонд вознаграждений ───

CREATE TABLE IF NOT EXISTS public.attribution_pools (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  -- Sources
  ad_revenue_total NUMERIC(12,2) DEFAULT 0,
  subscription_share_total NUMERIC(12,2) DEFAULT 0,
  marketplace_commission_total NUMERIC(12,2) DEFAULT 0,
  bonus_pool NUMERIC(12,2) DEFAULT 0,
  -- Calculated
  total_pool NUMERIC(12,2) DEFAULT 0,
  total_distributed NUMERIC(12,2) DEFAULT 0,
  total_eligible_creators INTEGER DEFAULT 0,
  total_engagement_points BIGINT DEFAULT 0,
  -- Status
  status TEXT DEFAULT 'accumulating' CHECK (status IN ('accumulating', 'calculating', 'distributed', 'archived')),
  calculated_at TIMESTAMPTZ,
  distributed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (period_start)
);

-- ─── 2. Attribution Shares — доли авторов в пуле ────────────

CREATE TABLE IF NOT EXISTS public.attribution_shares (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  pool_id UUID NOT NULL REFERENCES public.attribution_pools(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  -- Engagement metrics for the period
  total_plays BIGINT DEFAULT 0,
  unique_listeners INTEGER DEFAULT 0,
  total_likes INTEGER DEFAULT 0,
  total_shares INTEGER DEFAULT 0,
  total_comments INTEGER DEFAULT 0,
  total_saves INTEGER DEFAULT 0,
  -- Calculated
  engagement_score NUMERIC(14,2) DEFAULT 0,
  tier_multiplier NUMERIC(3,2) DEFAULT 1.0,
  quality_multiplier NUMERIC(3,2) DEFAULT 1.0,
  weighted_score NUMERIC(14,2) DEFAULT 0,
  pool_share_percent NUMERIC(8,6) DEFAULT 0,
  earned_amount NUMERIC(12,2) DEFAULT 0,
  -- Status
  paid_out BOOLEAN DEFAULT false,
  paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (pool_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_attribution_shares_user ON public.attribution_shares(user_id);
CREATE INDEX IF NOT EXISTS idx_attribution_shares_pool ON public.attribution_shares(pool_id);

-- ─── 3. Creator Earnings — накопленные заработки автора ──────

CREATE TABLE IF NOT EXISTS public.creator_earnings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL UNIQUE,
  -- Lifetime totals
  total_attribution NUMERIC(12,2) DEFAULT 0,
  total_marketplace_sales NUMERIC(12,2) DEFAULT 0,
  total_premium_content NUMERIC(12,2) DEFAULT 0,
  total_tips NUMERIC(12,2) DEFAULT 0,
  total_royalties NUMERIC(12,2) DEFAULT 0,
  total_earned NUMERIC(12,2) DEFAULT 0,
  -- Current period
  current_month_attribution NUMERIC(12,2) DEFAULT 0,
  current_month_sales NUMERIC(12,2) DEFAULT 0,
  current_month_total NUMERIC(12,2) DEFAULT 0,
  -- Payout
  pending_payout NUMERIC(12,2) DEFAULT 0,
  total_paid_out NUMERIC(12,2) DEFAULT 0,
  last_payout_at TIMESTAMPTZ,
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_creator_earnings_user ON public.creator_earnings(user_id);

-- ─── 4. Track Quality Scores — Quality Gate ─────────────────

CREATE TABLE IF NOT EXISTS public.track_quality_scores (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  track_id UUID NOT NULL UNIQUE,
  user_id UUID NOT NULL,
  -- Raw metrics (collected after 48h)
  engagement_rate NUMERIC(6,4) DEFAULT 0,
  completion_rate NUMERIC(6,4) DEFAULT 0,
  unique_listeners_48h INTEGER DEFAULT 0,
  save_rate NUMERIC(6,4) DEFAULT 0,
  skip_rate NUMERIC(6,4) DEFAULT 0,
  replay_rate NUMERIC(6,4) DEFAULT 0,
  -- Computed score
  quality_score NUMERIC(4,2) DEFAULT 0 CHECK (quality_score >= 0 AND quality_score <= 10),
  -- Flags
  eligible_for_feed BOOLEAN DEFAULT true,
  eligible_for_attribution BOOLEAN DEFAULT true,
  flagged_as_spam BOOLEAN DEFAULT false,
  -- Timestamps
  metrics_collected_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_track_quality_user ON public.track_quality_scores(user_id);
CREATE INDEX IF NOT EXISTS idx_track_quality_score ON public.track_quality_scores(quality_score);

-- ─── 5. Economy Health Snapshots — здоровье экономики ────────

CREATE TABLE IF NOT EXISTS public.economy_snapshots (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  snapshot_date DATE NOT NULL UNIQUE,
  -- Currency health
  total_rub_in_circulation BIGINT DEFAULT 0,
  rub_credited_today BIGINT DEFAULT 0,
  rub_spent_today BIGINT DEFAULT 0,
  rub_velocity NUMERIC(6,4) DEFAULT 0,
  -- User metrics
  total_users INTEGER DEFAULT 0,
  active_creators INTEGER DEFAULT 0,
  active_listeners INTEGER DEFAULT 0,
  paying_users INTEGER DEFAULT 0,
  -- Revenue
  daily_subscription_revenue NUMERIC(12,2) DEFAULT 0,
  daily_generation_revenue NUMERIC(12,2) DEFAULT 0,
  daily_marketplace_revenue NUMERIC(12,2) DEFAULT 0,
  daily_ad_revenue NUMERIC(12,2) DEFAULT 0,
  daily_total_revenue NUMERIC(12,2) DEFAULT 0,
  -- Costs
  daily_generation_cost NUMERIC(12,2) DEFAULT 0,
  daily_reward_payouts NUMERIC(12,2) DEFAULT 0,
  daily_total_cost NUMERIC(12,2) DEFAULT 0,
  -- Ratios
  revenue_cost_ratio NUMERIC(6,4) DEFAULT 0,
  creator_payout_ratio NUMERIC(6,4) DEFAULT 0,
  -- Content
  tracks_generated_today INTEGER DEFAULT 0,
  avg_quality_score NUMERIC(4,2) DEFAULT 0,
  spam_rate NUMERIC(6,4) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ─── 6. Economy Config — настройки экономики ─────────────────

CREATE TABLE IF NOT EXISTS public.economy_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '{}',
  label TEXT,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO public.economy_config (key, value, label, description) VALUES
  ('attribution', '{
    "enabled": true,
    "ad_revenue_share": 0.30,
    "subscription_share": 0.15,
    "marketplace_commission_share": 0.10,
    "min_tier_for_eligibility": "beat_maker",
    "min_quality_score": 3.0,
    "engagement_weights": {
      "play": 1,
      "unique_listener": 3,
      "like": 5,
      "share": 10,
      "comment": 3,
      "save": 7
    },
    "tier_multipliers": {
      "newcomer": 0,
      "beat_maker": 1.0,
      "sound_designer": 1.0,
      "producer": 1.5,
      "maestro": 2.0
    },
    "min_payout_amount": 100,
    "payout_delay_days": 7
  }', 'Attribution Pool', 'Настройки распределения доходов между авторами'),

  ('quality_gate', '{
    "enabled": true,
    "evaluation_delay_hours": 48,
    "min_score_for_feed": 3.0,
    "min_score_for_attribution": 3.0,
    "spam_threshold": 1.5,
    "score_weights": {
      "engagement_rate": 4.0,
      "completion_rate": 3.0,
      "unique_listeners": 2.0,
      "save_rate": 1.0
    },
    "author_warning_threshold": 4.0,
    "author_penalty_threshold": 2.5
  }', 'Quality Gate', 'Контроль качества треков — пороги, веса, фильтрация спама'),

  ('inflation_control', '{
    "xp_daily_cap": 150,
    "xp_weekly_soft_cap": 800,
    "xp_weekly_multiplier_after_cap": 0.5,
    "xp_monthly_hard_cap": 2500,
    "referral_delay_days": 3,
    "referral_min_activity": 5,
    "achievement_cooldown_hours": 1,
    "max_credits_from_achievements_monthly": 500,
    "wash_trade_detection_window_hours": 168,
    "self_play_detection": true
  }', 'Inflation Control', 'Антиинфляционные механизмы: лимиты XP, фрод-защита'),

  ('tier_privileges', '{
    "newcomer": {
      "marketplace_commission": 0.15,
      "attribution_eligible": false,
      "attribution_multiplier": 0,
      "bonus_generations": 0,
      "feed_boost": 1.0,
      "can_sell_premium": false,
      "can_create_voice_print": false
    },
    "beat_maker": {
      "marketplace_commission": 0.12,
      "attribution_eligible": true,
      "attribution_multiplier": 1.0,
      "bonus_generations": 5,
      "feed_boost": 1.2,
      "can_sell_premium": false,
      "can_create_voice_print": false
    },
    "sound_designer": {
      "marketplace_commission": 0.10,
      "attribution_eligible": true,
      "attribution_multiplier": 1.0,
      "bonus_generations": 10,
      "feed_boost": 1.5,
      "can_sell_premium": true,
      "can_create_voice_print": false
    },
    "producer": {
      "marketplace_commission": 0.07,
      "attribution_eligible": true,
      "attribution_multiplier": 1.5,
      "bonus_generations": 20,
      "feed_boost": 2.0,
      "can_sell_premium": true,
      "can_create_voice_print": true
    },
    "maestro": {
      "marketplace_commission": 0.05,
      "attribution_eligible": true,
      "attribution_multiplier": 2.0,
      "bonus_generations": 30,
      "feed_boost": 3.0,
      "can_sell_premium": true,
      "can_create_voice_print": true
    }
  }', 'Tier Privileges', 'Финансовые привилегии по уровням: комиссии, множители, доступ'),

  ('revenue_targets', '{
    "monthly_target_rub": 500000,
    "generation_cost_per_track_rub": 5.4,
    "target_margin_percent": 0.40,
    "avg_credits_per_rub": 2.0,
    "breakeven_credits_per_rub": 0.21,
    "critical_thresholds": {
      "10k_users": {"target_mrr": 200000, "max_attribution_pool": 60000},
      "100k_users": {"target_mrr": 2000000, "max_attribution_pool": 600000},
      "1m_users": {"target_mrr": 15000000, "max_attribution_pool": 4500000}
    }
  }', 'Revenue Targets', 'Целевые показатели доходов и пороги масштабирования')
ON CONFLICT (key) DO NOTHING;

-- ─── 7. Обновляем тир-привилегии в reputation_tiers ──────────

-- Добавляем колонки экономических привилегий
ALTER TABLE public.reputation_tiers
  ADD COLUMN IF NOT EXISTS marketplace_commission NUMERIC(4,3) DEFAULT 0.15,
  ADD COLUMN IF NOT EXISTS attribution_multiplier NUMERIC(3,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS bonus_generations INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS feed_boost NUMERIC(3,2) DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS can_sell_premium BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_create_voice_print BOOLEAN DEFAULT false;

-- Обновляем тиры с экономическими привилегиями
UPDATE public.reputation_tiers SET
  marketplace_commission = 0.15, attribution_multiplier = 0, bonus_generations = 0,
  feed_boost = 1.0, can_sell_premium = false, can_create_voice_print = false
WHERE key = 'newcomer';

UPDATE public.reputation_tiers SET
  marketplace_commission = 0.12, attribution_multiplier = 1.0, bonus_generations = 5,
  feed_boost = 1.2, can_sell_premium = false, can_create_voice_print = false
WHERE key = 'beat_maker';

UPDATE public.reputation_tiers SET
  marketplace_commission = 0.10, attribution_multiplier = 1.0, bonus_generations = 10,
  feed_boost = 1.5, can_sell_premium = true, can_create_voice_print = false
WHERE key = 'sound_designer';

UPDATE public.reputation_tiers SET
  marketplace_commission = 0.07, attribution_multiplier = 1.5, bonus_generations = 20,
  feed_boost = 2.0, can_sell_premium = true, can_create_voice_print = true
WHERE key = 'producer';

UPDATE public.reputation_tiers SET
  marketplace_commission = 0.05, attribution_multiplier = 2.0, bonus_generations = 30,
  feed_boost = 3.0, can_sell_premium = true, can_create_voice_print = true
WHERE key = 'maestro';

-- ─── 8. RPC: Расчёт Quality Score для трека ──────────────────

CREATE OR REPLACE FUNCTION public.calculate_track_quality(
  p_track_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_track RECORD;
  v_plays INTEGER;
  v_likes INTEGER;
  v_comments INTEGER;
  v_unique_listeners INTEGER;
  v_engagement NUMERIC;
  v_completion NUMERIC;
  v_save NUMERIC;
  v_score NUMERIC;
  v_config JSONB;
  v_weights JSONB;
BEGIN
  SELECT value INTO v_config FROM public.economy_config WHERE key = 'quality_gate';
  v_weights := v_config->'score_weights';

  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Track not found'); END IF;

  v_plays := COALESCE(v_track.plays_count, 0);
  v_likes := COALESCE(v_track.likes_count, 0);

  SELECT COUNT(*) INTO v_comments FROM public.track_comments WHERE track_id = p_track_id;

  -- Approximate unique listeners (plays with diminishing returns)
  v_unique_listeners := LEAST(v_plays, GREATEST(1, v_plays * 0.7)::INTEGER);

  -- Engagement rate: interactions / plays
  v_engagement := CASE WHEN v_plays > 0
    THEN LEAST(1.0, (v_likes + v_comments)::NUMERIC / v_plays)
    ELSE 0 END;

  -- Completion rate: approximate based on engagement
  v_completion := CASE WHEN v_plays > 10
    THEN LEAST(1.0, 0.5 + v_engagement * 0.5)
    ELSE 0.5 END;

  -- Save rate: approximate
  v_save := CASE WHEN v_plays > 0
    THEN LEAST(1.0, v_likes::NUMERIC / v_plays * 0.5)
    ELSE 0 END;

  -- Calculate weighted score (0-10 scale)
  v_score := LEAST(10.0, (
    v_engagement * COALESCE((v_weights->>'engagement_rate')::NUMERIC, 4.0) +
    v_completion * COALESCE((v_weights->>'completion_rate')::NUMERIC, 3.0) +
    LEAST(1.0, v_unique_listeners::NUMERIC / 50.0) * COALESCE((v_weights->>'unique_listeners')::NUMERIC, 2.0) +
    v_save * COALESCE((v_weights->>'save_rate')::NUMERIC, 1.0)
  ));

  -- Upsert quality score
  INSERT INTO public.track_quality_scores (
    track_id, user_id, engagement_rate, completion_rate,
    unique_listeners_48h, save_rate, quality_score,
    eligible_for_feed, eligible_for_attribution,
    flagged_as_spam, metrics_collected_at
  ) VALUES (
    p_track_id, v_track.user_id, v_engagement, v_completion,
    v_unique_listeners, v_save, v_score,
    v_score >= COALESCE((v_config->>'min_score_for_feed')::NUMERIC, 3.0),
    v_score >= COALESCE((v_config->>'min_score_for_attribution')::NUMERIC, 3.0),
    v_score < COALESCE((v_config->>'spam_threshold')::NUMERIC, 1.5),
    now()
  )
  ON CONFLICT (track_id) DO UPDATE SET
    engagement_rate = EXCLUDED.engagement_rate,
    completion_rate = EXCLUDED.completion_rate,
    unique_listeners_48h = EXCLUDED.unique_listeners_48h,
    save_rate = EXCLUDED.save_rate,
    quality_score = EXCLUDED.quality_score,
    eligible_for_feed = EXCLUDED.eligible_for_feed,
    eligible_for_attribution = EXCLUDED.eligible_for_attribution,
    flagged_as_spam = EXCLUDED.flagged_as_spam,
    metrics_collected_at = EXCLUDED.metrics_collected_at,
    updated_at = now();

  RETURN jsonb_build_object(
    'track_id', p_track_id,
    'quality_score', v_score,
    'engagement_rate', v_engagement,
    'completion_rate', v_completion,
    'unique_listeners', v_unique_listeners,
    'eligible_for_feed', v_score >= COALESCE((v_config->>'min_score_for_feed')::NUMERIC, 3.0),
    'eligible_for_attribution', v_score >= COALESCE((v_config->>'min_score_for_attribution')::NUMERIC, 3.0)
  );
END;
$$;

-- ─── 9. RPC: Economy Health Dashboard ────────────────────────

CREATE OR REPLACE FUNCTION public.get_economy_health()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total_balance BIGINT;
  v_total_users INTEGER;
  v_active_creators INTEGER;
  v_paying_users INTEGER;
  v_avg_quality NUMERIC;
  v_tracks_today INTEGER;
  v_generations_today INTEGER;
  v_top_earners JSONB;
  v_tier_distribution JSONB;
  v_recent_pool RECORD;
BEGIN
  -- Total ₽ in circulation
  SELECT COALESCE(SUM(balance), 0) INTO v_total_balance FROM public.profiles;

  -- User counts
  SELECT COUNT(*) INTO v_total_users FROM public.profiles;

  SELECT COUNT(DISTINCT user_id) INTO v_active_creators
  FROM public.tracks
  WHERE created_at > now() - INTERVAL '30 days' AND status = 'completed';

  SELECT COUNT(DISTINCT user_id) INTO v_paying_users
  FROM public.user_subscriptions
  WHERE status = 'active' AND current_period_end > now();

  -- Average track quality
  SELECT COALESCE(AVG(quality_score), 0) INTO v_avg_quality
  FROM public.track_quality_scores
  WHERE metrics_collected_at > now() - INTERVAL '30 days';

  -- Today's tracks
  SELECT COUNT(*) INTO v_tracks_today
  FROM public.tracks
  WHERE created_at > CURRENT_DATE AND status = 'completed';

  -- Tier distribution
  SELECT COALESCE(jsonb_agg(jsonb_build_object('tier', tier, 'count', cnt)), '[]'::jsonb)
  INTO v_tier_distribution
  FROM (
    SELECT COALESCE(tier, 'newcomer') as tier, COUNT(*) as cnt
    FROM public.forum_user_stats
    GROUP BY tier
    ORDER BY cnt DESC
  ) t;

  -- Top earners
  SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_top_earners
  FROM (
    SELECT ce.user_id, ce.total_earned, ce.current_month_total,
           p.username, p.avatar_url,
           fus.tier
    FROM public.creator_earnings ce
    JOIN public.profiles p ON p.user_id = ce.user_id
    LEFT JOIN public.forum_user_stats fus ON fus.user_id = ce.user_id
    ORDER BY ce.current_month_total DESC
    LIMIT 10
  ) e;

  -- Latest attribution pool
  SELECT * INTO v_recent_pool
  FROM public.attribution_pools
  ORDER BY period_start DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'currency', jsonb_build_object(
      'total_in_circulation', v_total_balance,
      'avg_per_user', CASE WHEN v_total_users > 0 THEN v_total_balance / v_total_users ELSE 0 END
    ),
    'users', jsonb_build_object(
      'total', v_total_users,
      'active_creators', v_active_creators,
      'paying', v_paying_users,
      'tier_distribution', v_tier_distribution
    ),
    'content', jsonb_build_object(
      'tracks_today', v_tracks_today,
      'avg_quality', v_avg_quality
    ),
    'attribution_pool', CASE WHEN v_recent_pool.id IS NOT NULL THEN jsonb_build_object(
      'id', v_recent_pool.id,
      'period', v_recent_pool.period_start || ' — ' || v_recent_pool.period_end,
      'total_pool', v_recent_pool.total_pool,
      'total_distributed', v_recent_pool.total_distributed,
      'eligible_creators', v_recent_pool.total_eligible_creators,
      'status', v_recent_pool.status
    ) ELSE '{}'::jsonb END,
    'top_earners', v_top_earners
  );
END;
$$;

-- ─── 10. RPC: Creator Earnings Profile ───────────────────────

CREATE OR REPLACE FUNCTION public.get_creator_earnings_profile(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_earnings RECORD;
  v_tier_info RECORD;
  v_privileges JSONB;
  v_recent_shares JSONB;
  v_quality_avg NUMERIC;
BEGIN
  -- Get or create earnings record
  INSERT INTO public.creator_earnings (user_id)
  VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT * INTO v_earnings FROM public.creator_earnings WHERE user_id = p_user_id;

  -- Get tier info
  SELECT fus.tier, fus.xp_total, rt.name_ru, rt.marketplace_commission,
         rt.attribution_multiplier, rt.bonus_generations, rt.feed_boost,
         rt.can_sell_premium, rt.can_create_voice_print
  INTO v_tier_info
  FROM public.forum_user_stats fus
  LEFT JOIN public.reputation_tiers rt ON rt.key = fus.tier
  WHERE fus.user_id = p_user_id;

  -- Recent attribution shares
  SELECT COALESCE(jsonb_agg(s ORDER BY s->>'period_start' DESC), '[]'::jsonb)
  INTO v_recent_shares
  FROM (
    SELECT jsonb_build_object(
      'period_start', ap.period_start,
      'engagement_score', ash.engagement_score,
      'earned_amount', ash.earned_amount,
      'pool_share_percent', ash.pool_share_percent
    ) as s
    FROM public.attribution_shares ash
    JOIN public.attribution_pools ap ON ap.id = ash.pool_id
    WHERE ash.user_id = p_user_id
    ORDER BY ap.period_start DESC
    LIMIT 6
  ) sub;

  -- Average quality score
  SELECT COALESCE(AVG(quality_score), 0) INTO v_quality_avg
  FROM public.track_quality_scores
  WHERE user_id = p_user_id AND metrics_collected_at > now() - INTERVAL '30 days';

  RETURN jsonb_build_object(
    'earnings', jsonb_build_object(
      'total_earned', COALESCE(v_earnings.total_earned, 0),
      'total_attribution', COALESCE(v_earnings.total_attribution, 0),
      'total_marketplace', COALESCE(v_earnings.total_marketplace_sales, 0),
      'total_premium', COALESCE(v_earnings.total_premium_content, 0),
      'total_tips', COALESCE(v_earnings.total_tips, 0),
      'total_royalties', COALESCE(v_earnings.total_royalties, 0),
      'current_month', COALESCE(v_earnings.current_month_total, 0),
      'pending_payout', COALESCE(v_earnings.pending_payout, 0)
    ),
    'tier', jsonb_build_object(
      'key', COALESCE(v_tier_info.tier, 'newcomer'),
      'name', COALESCE(v_tier_info.name_ru, 'Новичок'),
      'xp', COALESCE(v_tier_info.xp_total, 0),
      'commission', COALESCE(v_tier_info.marketplace_commission, 0.15),
      'attribution_multiplier', COALESCE(v_tier_info.attribution_multiplier, 0),
      'bonus_generations', COALESCE(v_tier_info.bonus_generations, 0),
      'feed_boost', COALESCE(v_tier_info.feed_boost, 1.0),
      'can_sell_premium', COALESCE(v_tier_info.can_sell_premium, false),
      'can_create_voice_print', COALESCE(v_tier_info.can_create_voice_print, false)
    ),
    'quality_avg', v_quality_avg,
    'recent_attribution', v_recent_shares
  );
END;
$$;

-- ─── 11. RLS Policies ───────────────────────────────────────

ALTER TABLE public.attribution_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attribution_shares ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.track_quality_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.economy_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.economy_config ENABLE ROW LEVEL SECURITY;

-- Attribution pools: read for all authenticated, write for admins
CREATE POLICY "attribution_pools_read" ON public.attribution_pools FOR SELECT TO authenticated USING (true);

-- Attribution shares: users see their own
CREATE POLICY "attribution_shares_read" ON public.attribution_shares FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM public.profiles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')));

-- Creator earnings: users see their own
CREATE POLICY "creator_earnings_read" ON public.creator_earnings FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM public.profiles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')));
CREATE POLICY "creator_earnings_insert" ON public.creator_earnings FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

-- Track quality: public read
CREATE POLICY "track_quality_read" ON public.track_quality_scores FOR SELECT TO authenticated USING (true);

-- Economy snapshots: admin only
CREATE POLICY "economy_snapshots_read" ON public.economy_snapshots FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')));

-- Economy config: admin read/write
CREATE POLICY "economy_config_read" ON public.economy_config FOR SELECT TO authenticated USING (true);
CREATE POLICY "economy_config_update" ON public.economy_config FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin')));
