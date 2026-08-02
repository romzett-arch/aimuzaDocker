BEGIN;

INSERT INTO public.moderation_events(
  track_id, track_user_id, actor_id, action, from_status, to_status,
  reason, notes, metadata, created_at
)
SELECT
  t.id, t.user_id, t.moderation_reviewed_by,
  CASE WHEN t.moderation_status = 'approved' THEN 'approved' ELSE 'rejected' END,
  'pending', t.moderation_status,
  t.moderation_rejection_reason, t.moderation_notes,
  jsonb_build_object('backfilled', true),
  COALESCE(t.moderation_reviewed_at, t.updated_at, t.created_at)
FROM public.tracks t
WHERE t.moderation_status IN ('approved', 'rejected')
  AND NOT EXISTS (
    SELECT 1 FROM public.moderation_events e
    WHERE e.track_id = t.id
      AND e.action = CASE WHEN t.moderation_status = 'approved' THEN 'approved' ELSE 'rejected' END
  );

COMMIT;
