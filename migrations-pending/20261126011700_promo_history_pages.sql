CREATE FUNCTION promotions.activation_history(p_limit integer, p_offset integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'title', c.title, 'expires_at', a.expires_at, 'image_resolution', c.image_resolution,
    'balance_amount', coalesce((a.rewards->>'balance')::integer, 0),
    'balance_reversed_at', (SELECT bt.created_at
      FROM public.balance_transactions bt
      JOIN promotions.topup_claims t ON t.payment_id = bt.reference_id
      WHERE bt.user_id = a.user_id AND bt.reference_type = 'promo_topup' AND bt.amount < 0
        AND t.campaign_id = a.campaign_id AND t.code_id = a.code_id
      ORDER BY bt.created_at DESC LIMIT 1),
    'bonuses', coalesce((SELECT jsonb_object_agg(g.kind, jsonb_build_object('total', g.total,
      'remaining', CASE WHEN a.expires_at > now() THEN g.remaining ELSE 0 END))
      FROM promotions.grants g WHERE g.activation_id = a.id), '{}')
  ) ORDER BY a.created_at DESC, a.id DESC), '[]')
  FROM (SELECT * FROM promotions.activations WHERE user_id = auth.uid() ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) a
  JOIN promotions.campaigns c ON c.id = a.campaign_id
$$;

CREATE OR REPLACE FUNCTION public.get_my_promo_bonuses()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT promotions.activation_history(100, 0)
$$;

CREATE FUNCTION public.get_my_promo_history(p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT promotions.activation_history(25, greatest(0, least(coalesce(p_offset, 0), 100000)))
$$;
REVOKE ALL ON FUNCTION promotions.activation_history(integer,integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_promo_history(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_promo_history(integer) TO authenticated;
