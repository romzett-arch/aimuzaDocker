-- The obsolete six-argument radio XP endpoint remained PUBLIC after the
-- canonical economy migration. Keep the function for dependency safety, but
-- make it unreachable by every API role.
REVOKE EXECUTE ON FUNCTION public.radio_award_listen_xp(uuid,uuid,integer,text,text,text)
  FROM PUBLIC,anon,authenticated,service_role;
