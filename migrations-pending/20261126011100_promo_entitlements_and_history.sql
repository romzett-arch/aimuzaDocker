CREATE INDEX promo_activations_user_history ON promotions.activations(user_id, created_at DESC, id DESC);

CREATE FUNCTION public.get_my_promo_entitlements()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(entitlements)), '[]')
  FROM (
    SELECT g.kind, sum(g.remaining)::integer AS remaining,
      CASE WHEN g.kind = 'image' THEN c.image_resolution END AS resolution
    FROM promotions.activations a
    JOIN promotions.grants g ON g.activation_id = a.id
    JOIN promotions.campaigns c ON c.id = a.campaign_id
    WHERE a.user_id = auth.uid() AND a.expires_at > now() AND g.remaining > 0
    GROUP BY g.kind, CASE WHEN g.kind = 'image' THEN c.image_resolution END
  ) entitlements
$$;
REVOKE ALL ON FUNCTION public.get_my_promo_entitlements() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_promo_entitlements() TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_promo_bonuses()
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
  FROM (SELECT * FROM promotions.activations WHERE user_id = auth.uid() ORDER BY created_at DESC, id DESC LIMIT 100) a
  JOIN promotions.campaigns c ON c.id = a.campaign_id
$$;
