-- Keep contest ballots and rankings independent from track voting.
LOCK TABLE public.contest_votes IN SHARE ROW EXCLUSIVE MODE;

CREATE OR REPLACE FUNCTION public.update_total_votes_received()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id uuid;
  v_contest_id uuid;
  v_delta integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_entry_id := NEW.entry_id;
    v_contest_id := NEW.contest_id;
    v_delta := 1;
  ELSE
    v_entry_id := OLD.entry_id;
    v_contest_id := OLD.contest_id;
    v_delta := -1;
  END IF;

  -- Serialize ballot counting with contest finalization.
  PERFORM 1 FROM public.contests WHERE id = v_contest_id AND status = 'voting' FOR SHARE;
  IF FOUND THEN
    UPDATE public.contest_entries
    SET votes_count = GREATEST(COALESCE(votes_count, 0) + v_delta, 0)
    WHERE id = v_entry_id AND contest_id = v_contest_id;
  END IF;

  UPDATE public.contest_ratings
  SET total_votes_received = GREATEST(total_votes_received + v_delta, 0)
  WHERE user_id = (SELECT user_id FROM public.contest_entries WHERE id = v_entry_id);

  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_total_votes_received()
FROM PUBLIC, anon, authenticated, service_role, aimuza_gateway;

WITH totals AS (
  SELECT entry.id, count(ballot.id)::integer AS votes
  FROM public.contest_entries AS entry
  JOIN public.contests AS contest ON contest.id = entry.contest_id AND contest.status = 'voting'
  LEFT JOIN public.contest_votes AS ballot ON ballot.entry_id = entry.id AND ballot.contest_id = contest.id
  GROUP BY entry.id
)
UPDATE public.contest_entries AS entry
SET votes_count = totals.votes
FROM totals
WHERE entry.id = totals.id AND entry.votes_count IS DISTINCT FROM totals.votes;
