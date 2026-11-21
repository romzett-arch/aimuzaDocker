ALTER TABLE public.max_chat_profiles
  ADD COLUMN max_display_name text CHECK (char_length(max_display_name) <= 160),
  ADD COLUMN max_name_seen_at timestamptz,
  ADD COLUMN last_interaction_at timestamptz;

-- Verification upgrades a MAX account in place and restores its website visibility.
CREATE FUNCTION public.is_max_only_profile(p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.max_chat_profiles m JOIN auth.users u ON u.id = m.user_id
    WHERE m.user_id = p_user_id AND u.email_confirmed_at IS NULL
      AND u.raw_user_meta_data->>'max_only' = 'true'
  );
$$;
REVOKE ALL ON FUNCTION public.is_max_only_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_max_only_profile(uuid) TO anon, authenticated;

CREATE POLICY exclude_max_only_from_site_profiles ON public.profiles AS RESTRICTIVE
  FOR SELECT TO anon, authenticated
  USING (user_id = (SELECT auth.uid()) OR NOT public.is_max_only_profile(user_id));
