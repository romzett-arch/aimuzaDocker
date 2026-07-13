-- Restore operational addon cards without mixing them into cash revenue.
CREATE OR REPLACE FUNCTION public.get_admin_monetization_dashboard()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_caller UUID := auth.uid();
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN RAISE EXCEPTION 'access_denied'; END IF;
  RETURN (
    WITH cash AS (
      SELECT COALESCE(SUM(amount) FILTER (WHERE status IN ('completed','succeeded') AND amount > 0),0)::BIGINT cash_inflow,
             COALESCE(SUM(amount) FILTER (WHERE status='refunded' AND amount > 0),0)::BIGINT cash_refunds,
             COUNT(*) FILTER (WHERE status IN ('completed','succeeded') AND amount > 0)::BIGINT topup_count
      FROM public.payments WHERE payment_system IN ('robokassa','yookassa')
    ), wallet AS (
      SELECT COALESCE(SUM(ABS(amount)) FILTER (WHERE amount<0 AND type NOT IN ('refund','payout_hold')),0)::BIGINT internal_consumption,
             COUNT(*) FILTER (WHERE amount<0 AND type NOT IN ('refund','payout_hold'))::BIGINT paid_operations
      FROM public.balance_transactions
    ), marketplace AS (
      SELECT COALESCE(SUM(platform_fee) FILTER (WHERE status<>'refunded'),0)::BIGINT fee,
             COALESCE(SUM(net_amount) FILTER (WHERE status IN ('pending','available')),0)::BIGINT seller_liability
      FROM public.seller_earnings
    ), costs AS (
      SELECT COALESCE(SUM(cost_rub) FILTER (WHERE status='completed'),0)::NUMERIC generation_cost FROM public.generation_logs
    ), service_charges AS (
      SELECT metadata->>'service_name' name, COUNT(*)::BIGINT charged, SUM(ABS(amount))::BIGINT revenue_rub
      FROM public.balance_transactions
      WHERE amount<0 AND NULLIF(metadata->>'service_name','') IS NOT NULL AND type NOT IN ('refund','payout_hold')
      GROUP BY metadata->>'service_name'
    ), track_ops AS (
      SELECT s.name, COUNT(ta.id)::BIGINT total,
             COUNT(ta.id) FILTER (WHERE ta.status='completed')::BIGINT completed,
             COUNT(ta.id) FILTER (WHERE ta.status='failed')::BIGINT failed
      FROM public.addon_services s LEFT JOIN public.track_addons ta ON ta.addon_service_id=s.id GROUP BY s.name
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
      'cashInflow',c.cash_inflow,'cashRefunds',c.cash_refunds,'netCashRevenue',c.cash_inflow-c.cash_refunds,
      'topupRevenue',c.cash_inflow,'topupCount',c.topup_count,
      'internalConsumption',w.internal_consumption,'platformRevenue',w.internal_consumption+m.fee,
      'marketplaceFeeRevenue',m.fee,'sellerLiability',m.seller_liability,
      'paidOperations',w.paid_operations,'actualGenerationCost',co.generation_cost,'addonStats',a.data
    ) FROM cash c CROSS JOIN wallet w CROSS JOIN marketplace m CROSS JOIN costs co CROSS JOIN addon_stats a
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_admin_monetization_dashboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_monetization_dashboard() TO authenticated;
