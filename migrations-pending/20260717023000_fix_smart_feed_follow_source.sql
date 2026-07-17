-- Keep the personalized feed on the same follow graph used by the application.
-- Older get_smart_feed versions still read public.follows, while follow/unfollow
-- mutations write to public.user_follows.
DO $migration$
DECLARE
  function_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_smart_feed(uuid,text,uuid,integer,integer)'::regprocedure
  )
  INTO function_definition;

  IF function_definition IS NULL THEN
    RAISE EXCEPTION 'public.get_smart_feed(uuid,text,uuid,integer,integer) is missing';
  END IF;

  IF position('FROM public.user_follows' IN function_definition) > 0 THEN
    RETURN;
  END IF;

  IF position('FROM public.follows' IN function_definition) = 0 THEN
    RAISE EXCEPTION 'get_smart_feed does not contain the expected public.follows source';
  END IF;

  EXECUTE replace(
    function_definition,
    'FROM public.follows',
    'FROM public.user_follows'
  );
END;
$migration$;
