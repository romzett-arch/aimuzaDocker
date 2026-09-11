-- Preserve financial history and user balances while starting the admin
-- monetization dashboard from a clean production baseline.
INSERT INTO public.system_settings (key, value, description, updated_at)
VALUES (
  'monetization_dashboard_reset',
  jsonb_build_object('reset_at', now()),
  'Точка отсечения финансовой статистики административного дашборда',
  now()
)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = EXCLUDED.updated_at;

CREATE OR REPLACE FUNCTION public.get_admin_monetization_dashboard(p_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_days INTEGER := GREATEST(1, LEAST(COALESCE(p_days,30),3650));
  v_from TIMESTAMPTZ := date_trunc('day', timezone('Europe/Moscow',now()) - (v_days-1)*interval '1 day') AT TIME ZONE 'Europe/Moscow';
  v_reset_at TIMESTAMPTZ;
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN RAISE EXCEPTION 'access_denied'; END IF;

  SELECT NULLIF(value->>'reset_at','')::timestamptz
  INTO v_reset_at
  FROM public.system_settings
  WHERE key='monetization_dashboard_reset';

  v_from := GREATEST(v_from, COALESCE(v_reset_at, v_from));

  RETURN (
    WITH cash AS (
      SELECT COALESCE(SUM(amount) FILTER (WHERE status IN ('completed','succeeded') AND amount>0),0)::BIGINT cash_inflow,
             COALESCE(SUM(amount) FILTER (WHERE status='refunded' AND amount>0),0)::BIGINT cash_refunds,
             COUNT(*) FILTER (WHERE status IN ('completed','succeeded') AND amount>0)::BIGINT topup_count
      FROM public.payments WHERE payment_system IN ('robokassa','yookassa') AND created_at>=v_from
    ), wallet_rows AS (
      SELECT * FROM public.balance_transactions
      WHERE created_at>=v_from AND amount<0 AND type NOT IN ('refund','payout_hold')
    ), wallet AS (
      SELECT COALESCE(SUM(ABS(amount)),0)::BIGINT internal_consumption, COUNT(*)::BIGINT paid_operations,
             COALESCE(SUM(ABS(amount)) FILTER (WHERE type NOT IN (
               'debit','generation','forum_ai','addon_service','lyrics_gen','purchase',
               'track_deposit','lyrics_deposit','video','contest_entry_fee','item_purchase'
             )),0)::BIGINT unclassified_amount,
             COUNT(*) FILTER (WHERE type NOT IN (
               'debit','generation','forum_ai','addon_service','lyrics_gen','purchase',
               'track_deposit','lyrics_deposit','video','contest_entry_fee','item_purchase'
             ))::BIGINT unclassified_count
      FROM wallet_rows
    ), marketplace AS (
      SELECT COALESCE(SUM(platform_fee) FILTER (WHERE status<>'refunded' AND created_at>=v_from),0)::BIGINT fee,
             COALESCE(SUM(net_amount) FILTER (WHERE status IN ('pending','available') AND created_at>=v_from),0)::BIGINT seller_liability
      FROM public.seller_earnings
    ), costs AS (
      SELECT COALESCE(SUM(cost_rub) FILTER (WHERE status='completed' AND created_at>=v_from),0)::NUMERIC generation_cost
      FROM public.generation_logs
    ), service_charges AS (
      SELECT metadata->>'service_name' name,COUNT(*)::BIGINT charged,SUM(ABS(amount))::BIGINT revenue_rub
      FROM wallet_rows WHERE NULLIF(metadata->>'service_name','') IS NOT NULL GROUP BY metadata->>'service_name'
    ), track_ops AS (
      SELECT s.name,COUNT(ta.id)::BIGINT total,
             COUNT(ta.id) FILTER (WHERE ta.status='completed')::BIGINT completed,
             COUNT(ta.id) FILTER (WHERE ta.status='failed')::BIGINT failed
      FROM public.addon_services s LEFT JOIN public.track_addons ta ON ta.addon_service_id=s.id AND ta.created_at>=v_from
      GROUP BY s.name
    ), addon_stats AS (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'name',s.name,'name_ru',s.name_ru,'price_rub',s.price_rub,
        'total',GREATEST(COALESCE(o.total,0),COALESCE(sc.charged,0)),
        'charged',COALESCE(sc.charged,0),'completed',COALESCE(o.completed,0),
        'failed',COALESCE(o.failed,0),'revenue_rub',COALESCE(sc.revenue_rub,0)
      ) ORDER BY s.sort_order,s.name),'[]'::jsonb) data
      FROM public.addon_services s LEFT JOIN service_charges sc ON sc.name=s.name LEFT JOIN track_ops o ON o.name=s.name
    )
    SELECT jsonb_build_object(
      'periodDays',v_days,'periodFrom',v_from,
      'cashInflow',c.cash_inflow,'cashRefunds',c.cash_refunds,'netCashRevenue',c.cash_inflow-c.cash_refunds,
      'topupRevenue',c.cash_inflow,'topupCount',c.topup_count,
      'internalConsumption',w.internal_consumption,'platformRevenue',w.internal_consumption+m.fee,
      'unclassifiedAmount',w.unclassified_amount,'unclassifiedCount',w.unclassified_count,
      'marketplaceFeeRevenue',m.fee,'sellerLiability',m.seller_liability,
      'paidOperations',w.paid_operations,'actualGenerationCost',co.generation_cost,'addonStats',a.data
    ) FROM cash c CROSS JOIN wallet w CROSS JOIN marketplace m CROSS JOIN costs co CROSS JOIN addon_stats a
  );
END;
$function$;

