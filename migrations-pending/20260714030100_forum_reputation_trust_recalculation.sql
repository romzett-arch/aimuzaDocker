BEGIN;

-- Legacy trust levels used another scale. Normalize existing rows once to the
-- authoritative thresholds introduced by the reputation reliability migration.
UPDATE public.forum_user_stats s
SET trust_level = COALESCE((
      SELECT max(c.trust_level)
      FROM public.forum_reputation_config c
      WHERE c.trust_level IS NOT NULL
        AND c.min_reputation <= s.reputation
    ), 0),
    updated_at = now();

COMMIT;
