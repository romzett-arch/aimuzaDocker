-- 1. Show is_admin function
\sf public.is_admin

-- 2. All custom functions that reference roles
SELECT proname, prosrc 
FROM pg_proc 
WHERE prosrc LIKE '%admin%' OR prosrc LIKE '%super_admin%' OR prosrc LIKE '%role%'
AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY proname;

-- 3. All RLS policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check 
FROM pg_policies 
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- 4. All trigger functions
SELECT tgname, tgrelid::regclass, proname 
FROM pg_trigger t 
JOIN pg_proc p ON p.oid = t.tgfoid 
WHERE NOT tgisinternal
ORDER BY tgrelid::regclass::text;
