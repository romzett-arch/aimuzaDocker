SELECT proname, pg_get_function_arguments(p.oid) as args
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace=n.oid
WHERE n.nspname='public'
  AND proname IN ('fn_add_xp','get_hero_stats','get_last_messages','award_xp')
ORDER BY proname;
