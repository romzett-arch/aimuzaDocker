CREATE OR REPLACE FUNCTION public.get_admin_monetization_dashboard()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION 'access_denied';
  END IF;

  RETURN (
    WITH topups AS (
      SELECT
        COALESCE(SUM(p.amount), 0)::BIGINT AS topup_revenue,
        COUNT(*) FILTER (WHERE p.amount > 0)::BIGINT AS topup_count
      FROM public.payments p
      WHERE p.payment_system IN ('robokassa', 'yookassa')
        AND p.status IN ('completed', 'succeeded')
        AND p.amount > 0
    ),
    marketplace AS (
      SELECT COALESCE(SUM(se.platform_fee), 0)::BIGINT AS marketplace_fee_revenue
      FROM public.seller_earnings se
    ),
    tx_effects AS (
      SELECT
        CASE
          WHEN bt.type = 'forum_ai' THEN
            CASE bt.metadata ->> 'mode'
              WHEN 'spell_check' THEN 'forum_spell_check'
              WHEN 'expand_topic' THEN 'forum_expand_topic'
              WHEN 'expand_to_topic' THEN 'forum_expand_topic'
              WHEN 'expand_reply' THEN 'forum_expand_reply'
              WHEN 'summarize_thread' THEN 'forum_summarize_thread'
              WHEN 'suggest_arguments' THEN 'forum_suggest_arguments'
              ELSE NULL
            END
          WHEN bt.type = 'lyrics_gen' THEN COALESCE(NULLIF(bt.metadata ->> 'service_name', ''), 'generate_lyrics')
          WHEN bt.type = 'addon_service' AND LOWER(bt.description) LIKE '%wav%' THEN COALESCE(NULLIF(bt.metadata ->> 'service_name', ''), 'convert_wav')
          WHEN bt.type = 'addon_service' AND LOWER(bt.description) LIKE '%без рекламы%' THEN 'ad_free'
          WHEN bt.type = 'addon_service' THEN NULLIF(bt.metadata ->> 'service_name', '')
          WHEN bt.type = 'debit' AND LOWER(bt.description) LIKE '%кавер%' THEN COALESCE(NULLIF(bt.metadata ->> 'service_name', ''), 'upload_cover')
          WHEN bt.type = 'debit' AND LOWER(bt.description) LIKE '%промпт%' THEN COALESCE(NULLIF(bt.metadata ->> 'service_name', ''), 'create_prompt')
          WHEN bt.type = 'purchase' AND COALESCE(bt.metadata ->> 'service_name', '') LIKE 'boost_track_%' THEN bt.metadata ->> 'service_name'
          WHEN bt.type = 'purchase' AND (
            COALESCE(bt.metadata ->> 'service_name', '') = 'track_upload_pack_10'
            OR LOWER(bt.description) LIKE '%пакет загрузки%'
            OR LOWER(bt.description) LIKE '%загрузка трека (сверх лимита)%'
          ) THEN 'track_upload_pack_10'
          ELSE NULL
        END AS service_name,
        CASE
          WHEN bt.type = 'addon_service' AND LOWER(bt.description) LIKE '%без рекламы%' THEN 'ad_free'
          WHEN bt.type = 'debit'
            AND LOWER(bt.description) NOT LIKE '%кавер%'
            AND LOWER(bt.description) NOT LIKE '%промпт%' THEN 'generation'
          WHEN bt.type IN ('forum_ai', 'addon_service', 'lyrics_gen')
            OR (
              bt.type = 'debit'
              AND (
                LOWER(bt.description) LIKE '%кавер%'
                OR LOWER(bt.description) LIKE '%промпт%'
              )
            ) THEN 'addons'
          WHEN bt.type = 'purchase' AND LOWER(bt.description) LIKE 'подписка %' THEN 'subscriptions'
          WHEN bt.type = 'purchase' AND COALESCE(bt.metadata ->> 'service_name', '') LIKE 'boost_track_%' THEN 'boosts'
          WHEN bt.type = 'purchase' AND (
            COALESCE(bt.metadata ->> 'service_name', '') = 'track_upload_pack_10'
            OR LOWER(bt.description) LIKE '%пакет загрузки%'
            OR LOWER(bt.description) LIKE '%загрузка трека (сверх лимита)%'
          ) THEN 'upload_packs'
          WHEN bt.type IN ('track_deposit', 'lyrics_deposit') THEN 'deposits'
          ELSE 'other'
        END AS revenue_bucket,
        CASE
          WHEN bt.amount < 0 THEN ABS(bt.amount)::BIGINT
          WHEN bt.type = 'refund' AND bt.amount > 0 THEN -bt.amount::BIGINT
          ELSE 0::BIGINT
        END AS revenue_delta,
        CASE
          WHEN bt.amount < 0 THEN 1::BIGINT
          ELSE 0::BIGINT
        END AS operations_count
      FROM public.balance_transactions bt
      WHERE bt.amount < 0
         OR (bt.type = 'refund' AND bt.amount > 0)
    ),
    revenue AS (
      SELECT
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'generation'), 0)::BIGINT AS generation_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'addons'), 0)::BIGINT AS addon_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'subscriptions'), 0)::BIGINT AS subscription_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'boosts'), 0)::BIGINT AS boost_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'upload_packs'), 0)::BIGINT AS upload_pack_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'deposits'), 0)::BIGINT AS deposit_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'ad_free'), 0)::BIGINT AS ad_free_revenue,
        COALESCE(SUM(te.revenue_delta) FILTER (WHERE te.revenue_bucket = 'other'), 0)::BIGINT AS other_revenue,
        COALESCE(SUM(te.operations_count), 0)::BIGINT AS paid_operations
      FROM tx_effects te
    ),
    service_revenue AS (
      SELECT
        te.service_name,
        COALESCE(SUM(te.operations_count), 0)::BIGINT AS charged,
        COALESCE(SUM(te.revenue_delta), 0)::BIGINT AS revenue_rub
      FROM tx_effects te
      WHERE te.service_name IS NOT NULL
        AND te.service_name <> 'ad_free'
      GROUP BY te.service_name
    ),
    track_ops AS (
      SELECT
        s.name,
        COUNT(ta.id)::BIGINT AS total,
        COUNT(*) FILTER (WHERE ta.status = 'completed')::BIGINT AS completed,
        COUNT(*) FILTER (WHERE ta.status = 'failed')::BIGINT AS failed
      FROM public.addon_services s
      LEFT JOIN public.track_addons ta ON ta.addon_service_id = s.id
      GROUP BY s.name
    ),
    separation_ops AS (
      SELECT
        CASE a.type
          WHEN 'vocal' THEN 'vocal_separation'
          WHEN 'stems' THEN 'stem_separation'
          ELSE a.type
        END AS name,
        COUNT(*)::BIGINT AS total,
        COUNT(*) FILTER (WHERE a.status IN ('completed', 'processing'))::BIGINT AS completed,
        COUNT(*) FILTER (WHERE a.status = 'failed')::BIGINT AS failed
      FROM public.audio_separations a
      GROUP BY 1
    ),
    operational_stats AS (
      SELECT
        x.name,
        SUM(x.total)::BIGINT AS total,
        SUM(x.completed)::BIGINT AS completed,
        SUM(x.failed)::BIGINT AS failed
      FROM (
        SELECT name, total, completed, failed FROM track_ops
        UNION ALL
        SELECT name, total, completed, failed FROM separation_ops
      ) x
      GROUP BY x.name
    ),
    addon_stats AS (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'name', s.name,
            'name_ru', s.name_ru,
            'price_rub', s.price_rub,
            'total', CASE
              WHEN COALESCE(o.total, 0) > 0 THEN COALESCE(o.total, 0)
              ELSE COALESCE(sr.charged, 0)
            END,
            'charged', COALESCE(sr.charged, 0),
            'completed', CASE
              WHEN COALESCE(o.total, 0) > 0 THEN COALESCE(o.completed, 0)
              ELSE COALESCE(sr.charged, 0)
            END,
            'failed', COALESCE(o.failed, 0),
            'revenue_rub', COALESCE(sr.revenue_rub, 0)
          )
          ORDER BY s.sort_order, s.name
        ),
        '[]'::JSONB
      ) AS data
      FROM public.addon_services s
      LEFT JOIN service_revenue sr ON sr.service_name = s.name
      LEFT JOIN operational_stats o ON o.name = s.name
      WHERE s.is_active = true
    )
    SELECT jsonb_build_object(
      'topupRevenue', t.topup_revenue,
      'topupCount', t.topup_count,
      'generationRevenue', r.generation_revenue,
      'addonRevenue', r.addon_revenue,
      'subscriptionRevenue', r.subscription_revenue,
      'boostRevenue', r.boost_revenue,
      'uploadPackRevenue', r.upload_pack_revenue,
      'depositRevenue', r.deposit_revenue,
      'adFreeRevenue', r.ad_free_revenue,
      'otherRevenue', r.other_revenue,
      'marketplaceFeeRevenue', m.marketplace_fee_revenue,
      'paidOperations', r.paid_operations,
      'platformRevenue',
        r.generation_revenue +
        r.addon_revenue +
        r.subscription_revenue +
        r.boost_revenue +
        r.upload_pack_revenue +
        r.deposit_revenue +
        r.ad_free_revenue +
        r.other_revenue +
        m.marketplace_fee_revenue,
      'addonStats', a.data
    )
    FROM topups t
    CROSS JOIN revenue r
    CROSS JOIN marketplace m
    CROSS JOIN addon_stats a
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_monetization_dashboard() TO authenticated;

CREATE OR REPLACE FUNCTION public.get_admin_gateway_payments_dashboard(p_days INTEGER DEFAULT 30)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_days INTEGER := GREATEST(1, LEAST(COALESCE(p_days, 30), 365));
  v_today DATE := timezone('Europe/Moscow', now())::DATE;
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION 'access_denied';
  END IF;

  RETURN (
    WITH payment_rows AS (
      SELECT
        p.amount,
        p.status,
        p.created_at,
        timezone('Europe/Moscow', p.created_at)::DATE AS local_date
      FROM public.payments p
      WHERE p.payment_system IN ('robokassa', 'yookassa')
    ),
    stats AS (
      SELECT jsonb_build_object(
        'total', COUNT(*)::BIGINT,
        'completed', COUNT(*) FILTER (WHERE pr.status IN ('completed', 'succeeded'))::BIGINT,
        'pending', COUNT(*) FILTER (WHERE pr.status = 'pending')::BIGINT,
        'cancelled', COUNT(*) FILTER (WHERE pr.status IN ('cancelled', 'failed'))::BIGINT,
        'refunded', COUNT(*) FILTER (WHERE pr.status = 'refunded')::BIGINT,
        'stale', COUNT(*) FILTER (
          WHERE pr.status = 'pending'
            AND pr.created_at < now() - INTERVAL '30 minutes'
        )::BIGINT,
        'revenueToday', COALESCE(SUM(pr.amount) FILTER (
          WHERE pr.status IN ('completed', 'succeeded')
            AND pr.amount > 0
            AND pr.local_date = v_today
        ), 0)::BIGINT,
        'revenueWeek', COALESCE(SUM(pr.amount) FILTER (
          WHERE pr.status IN ('completed', 'succeeded')
            AND pr.amount > 0
            AND pr.local_date >= (v_today - 6)
        ), 0)::BIGINT,
        'revenueMonth', COALESCE(SUM(pr.amount) FILTER (
          WHERE pr.status IN ('completed', 'succeeded')
            AND pr.amount > 0
            AND pr.local_date >= (v_today - 29)
        ), 0)::BIGINT,
        'revenueTotal', COALESCE(SUM(pr.amount) FILTER (
          WHERE pr.status IN ('completed', 'succeeded')
            AND pr.amount > 0
        ), 0)::BIGINT
      ) AS data
      FROM payment_rows pr
    ),
    day_series AS (
      SELECT generate_series(v_today - (v_days - 1), v_today, INTERVAL '1 day')::DATE AS day
    ),
    revenue_by_day AS (
      SELECT
        pr.local_date AS day,
        COALESCE(SUM(pr.amount), 0)::BIGINT AS amount,
        COUNT(*)::BIGINT AS count
      FROM payment_rows pr
      WHERE pr.status IN ('completed', 'succeeded')
        AND pr.amount > 0
        AND pr.local_date >= (v_today - (v_days - 1))
      GROUP BY pr.local_date
    ),
    chart AS (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'date', to_char(ds.day, 'YYYY-MM-DD'),
            'amount', COALESCE(rbd.amount, 0),
            'count', COALESCE(rbd.count, 0)
          )
          ORDER BY ds.day
        ),
        '[]'::JSONB
      ) AS data
      FROM day_series ds
      LEFT JOIN revenue_by_day rbd ON rbd.day = ds.day
    )
    SELECT jsonb_build_object(
      'stats', s.data,
      'chart', c.data
    )
    FROM stats s
    CROSS JOIN chart c
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_gateway_payments_dashboard(INTEGER) TO authenticated;
