-- ==========================================================
-- FORUM SANCTIONS: canonical enforcement + legacy sync
-- ==========================================================

CREATE TABLE IF NOT EXISTS public.forum_user_bans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  ban_zone TEXT NOT NULL DEFAULT 'forum',
  reason TEXT,
  banned_by UUID,
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  cooldown_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_user_bans ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.forum_user_bans
  ADD COLUMN IF NOT EXISTS ban_zone TEXT,
  ADD COLUMN IF NOT EXISTS banned_by UUID,
  ADD COLUMN IF NOT EXISTS reason TEXT,
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS cooldown_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_user_bans'
      AND column_name = 'ban_type'
  ) THEN
    EXECUTE '
      UPDATE public.forum_user_bans
      SET ban_zone = COALESCE(
        ban_zone,
        CASE ban_type
          WHEN ''full'' THEN ''account''
          WHEN ''account'' THEN ''account''
          WHEN ''comment'' THEN ''comments''
          WHEN ''comments'' THEN ''comments''
          ELSE ''forum''
        END
      )
      WHERE ban_zone IS NULL
    ';
  END IF;
END $$;

UPDATE public.forum_user_bans
SET ban_zone = 'forum'
WHERE ban_zone IS NULL OR btrim(ban_zone) = '';

CREATE INDEX IF NOT EXISTS idx_forum_user_bans_active
  ON public.forum_user_bans(user_id, ban_zone, is_active, expires_at);

CREATE TABLE IF NOT EXISTS public.forum_warning_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE,
  total_points INTEGER NOT NULL DEFAULT 0,
  last_decay_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_warning_points ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.forum_warning_points
  ADD COLUMN IF NOT EXISTS total_points INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_decay_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS public.forum_warnings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  issued_by UUID NOT NULL,
  reason TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'warning',
  duration_hours INTEGER,
  expires_at TIMESTAMPTZ,
  post_id UUID REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  topic_id UUID REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  is_active BOOLEAN DEFAULT true,
  acknowledged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.forum_warnings ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.forum_warnings
  ADD COLUMN IF NOT EXISTS issued_by UUID,
  ADD COLUMN IF NOT EXISTS duration_hours INTEGER,
  ADD COLUMN IF NOT EXISTS acknowledged_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_warnings'
      AND column_name = 'moderator_id'
  ) THEN
    EXECUTE '
      UPDATE public.forum_warnings
      SET issued_by = COALESCE(issued_by, moderator_id)
      WHERE issued_by IS NULL
    ';
  END IF;
END $$;

UPDATE public.forum_warnings
SET is_active = true
WHERE is_active IS NULL;

CREATE INDEX IF NOT EXISTS idx_forum_warnings_user_active
  ON public.forum_warnings(user_id, is_active, expires_at);

ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS is_banned BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS banned_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ban_reason TEXT,
  ADD COLUMN IF NOT EXISTS is_muted BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS muted_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS is_silenced BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS silenced_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS silence_reason TEXT,
  ADD COLUMN IF NOT EXISTS warnings_count INTEGER DEFAULT 0;

CREATE OR REPLACE FUNCTION public.forum_is_sanction_active(
  p_is_active BOOLEAN,
  p_expires_at TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(p_is_active, true) AND (p_expires_at IS NULL OR p_expires_at > now());
$$;

CREATE OR REPLACE FUNCTION public.forum_has_active_ban(
  _user_id UUID,
  _zones TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.forum_user_bans b
    WHERE b.user_id = _user_id
      AND b.ban_zone = ANY(_zones)
      AND public.forum_is_sanction_active(b.is_active, b.expires_at)
  );
$$;

CREATE OR REPLACE FUNCTION public.forum_user_trust_level(p_user_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT trust_level FROM public.forum_user_stats WHERE user_id = p_user_id),
    0
  );
$$;

CREATE OR REPLACE FUNCTION public.forum_user_is_banned(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    EXISTS (
      SELECT 1
      FROM public.forum_user_stats s
      WHERE s.user_id = p_user_id
        AND COALESCE(s.is_banned, false)
        AND (s.banned_until IS NULL OR s.banned_until > now())
    ),
    false
  ) OR public.forum_has_active_ban(p_user_id, ARRAY['forum', 'account']);
$$;

CREATE OR REPLACE FUNCTION public.forum_user_is_muted(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    EXISTS (
      SELECT 1
      FROM public.forum_user_stats s
      WHERE s.user_id = _user_id
        AND COALESCE(s.is_muted, false)
        AND (s.muted_until IS NULL OR s.muted_until > now())
    ),
    false
  ) OR public.forum_has_active_ban(_user_id, ARRAY['comments']);
$$;

CREATE OR REPLACE FUNCTION public.forum_user_is_silenced(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    EXISTS (
      SELECT 1
      FROM public.forum_user_stats s
      WHERE s.user_id = _user_id
        AND COALESCE(s.is_silenced, false)
        AND (s.silenced_until IS NULL OR s.silenced_until > now())
    ),
    false
  ) OR EXISTS (
    SELECT 1
    FROM public.forum_warnings w
    WHERE w.user_id = _user_id
      AND COALESCE(w.is_active, true)
      AND w.severity = 'silence'
      AND (w.expires_at IS NULL OR w.expires_at > now())
  );
$$;

CREATE OR REPLACE FUNCTION public.forum_can_create_topic(
  _user_id UUID,
  _category_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_required_trust_level INTEGER := 0;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_categories'
      AND column_name = 'min_trust_level'
  ) THEN
    EXECUTE
      'SELECT COALESCE(min_trust_level, 0) FROM public.forum_categories WHERE id = $1'
      INTO v_required_trust_level
      USING _category_id;
  END IF;

  RETURN
    _user_id IS NOT NULL
    AND NOT public.forum_user_is_banned(_user_id)
    AND NOT public.forum_user_is_silenced(_user_id)
    AND public.forum_user_trust_level(_user_id) >= COALESCE(v_required_trust_level, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_can_create_post(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    _user_id IS NOT NULL
    AND NOT public.forum_user_is_banned(_user_id)
    AND NOT public.forum_user_is_silenced(_user_id)
    AND NOT public.forum_user_is_muted(_user_id);
$$;

CREATE OR REPLACE FUNCTION public.forum_refresh_user_moderation_state(_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats public.forum_user_stats%ROWTYPE;
  v_forum_ban RECORD;
  v_comment_ban RECORD;
  v_silence_warning RECORD;
  v_active_warnings INTEGER := 0;
  v_effective_banned BOOLEAN := false;
  v_effective_muted BOOLEAN := false;
  v_effective_silenced BOOLEAN := false;
BEGIN
  IF _user_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.forum_user_stats (user_id)
  VALUES (_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT * INTO v_stats
  FROM public.forum_user_stats
  WHERE user_id = _user_id;

  SELECT b.reason, b.expires_at
  INTO v_forum_ban
  FROM public.forum_user_bans b
  WHERE b.user_id = _user_id
    AND b.ban_zone IN ('forum', 'account')
    AND public.forum_is_sanction_active(b.is_active, b.expires_at)
  ORDER BY b.created_at DESC
  LIMIT 1;

  SELECT b.reason, b.expires_at
  INTO v_comment_ban
  FROM public.forum_user_bans b
  WHERE b.user_id = _user_id
    AND b.ban_zone = 'comments'
    AND public.forum_is_sanction_active(b.is_active, b.expires_at)
  ORDER BY b.created_at DESC
  LIMIT 1;

  SELECT w.reason, w.expires_at
  INTO v_silence_warning
  FROM public.forum_warnings w
  WHERE w.user_id = _user_id
    AND COALESCE(w.is_active, true)
    AND w.severity = 'silence'
    AND (w.expires_at IS NULL OR w.expires_at > now())
  ORDER BY w.created_at DESC
  LIMIT 1;

  SELECT COUNT(*)
  INTO v_active_warnings
  FROM public.forum_warnings w
  WHERE w.user_id = _user_id
    AND COALESCE(w.is_active, true)
    AND (w.expires_at IS NULL OR w.expires_at > now());

  v_effective_banned := (
    (COALESCE(v_stats.is_banned, false) AND (v_stats.banned_until IS NULL OR v_stats.banned_until > now()))
    OR v_forum_ban IS NOT NULL
  );

  v_effective_muted := (
    (COALESCE(v_stats.is_muted, false) AND (v_stats.muted_until IS NULL OR v_stats.muted_until > now()))
    OR v_comment_ban IS NOT NULL
  );

  v_effective_silenced := (
    (COALESCE(v_stats.is_silenced, false) AND (v_stats.silenced_until IS NULL OR v_stats.silenced_until > now()))
    OR v_silence_warning IS NOT NULL
  );

  UPDATE public.forum_user_stats
  SET
    warnings_count = v_active_warnings,
    is_banned = v_effective_banned,
    banned_until = CASE
      WHEN v_forum_ban IS NOT NULL THEN v_forum_ban.expires_at
      WHEN COALESCE(v_stats.is_banned, false) AND (v_stats.banned_until IS NULL OR v_stats.banned_until > now()) THEN v_stats.banned_until
      ELSE NULL
    END,
    ban_reason = CASE
      WHEN v_forum_ban IS NOT NULL THEN COALESCE(v_forum_ban.reason, v_stats.ban_reason)
      WHEN COALESCE(v_stats.is_banned, false) AND (v_stats.banned_until IS NULL OR v_stats.banned_until > now()) THEN v_stats.ban_reason
      ELSE NULL
    END,
    is_muted = v_effective_muted,
    muted_until = CASE
      WHEN v_comment_ban IS NOT NULL THEN v_comment_ban.expires_at
      WHEN COALESCE(v_stats.is_muted, false) AND (v_stats.muted_until IS NULL OR v_stats.muted_until > now()) THEN v_stats.muted_until
      ELSE NULL
    END,
    is_silenced = v_effective_silenced,
    silenced_until = CASE
      WHEN v_silence_warning IS NOT NULL THEN v_silence_warning.expires_at
      WHEN COALESCE(v_stats.is_silenced, false) AND (v_stats.silenced_until IS NULL OR v_stats.silenced_until > now()) THEN v_stats.silenced_until
      ELSE NULL
    END,
    silence_reason = CASE
      WHEN v_silence_warning IS NOT NULL THEN COALESCE(v_silence_warning.reason, v_stats.silence_reason)
      WHEN COALESCE(v_stats.is_silenced, false) AND (v_stats.silenced_until IS NULL OR v_stats.silenced_until > now()) THEN v_stats.silence_reason
      ELSE NULL
    END,
    updated_at = now()
  WHERE user_id = _user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_refresh_user_moderation_state_from_ban()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.forum_refresh_user_moderation_state(COALESCE(NEW.user_id, OLD.user_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_refresh_user_moderation_state_from_warning()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.forum_refresh_user_moderation_state(COALESCE(NEW.user_id, OLD.user_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_refresh_user_moderation_state_ban ON public.forum_user_bans;
CREATE TRIGGER trg_forum_refresh_user_moderation_state_ban
  AFTER INSERT OR UPDATE OR DELETE ON public.forum_user_bans
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_refresh_user_moderation_state_from_ban();

DROP TRIGGER IF EXISTS trg_forum_refresh_user_moderation_state_warning ON public.forum_warnings;
CREATE TRIGGER trg_forum_refresh_user_moderation_state_warning
  AFTER INSERT OR UPDATE OR DELETE ON public.forum_warnings
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_refresh_user_moderation_state_from_warning();

CREATE OR REPLACE FUNCTION public.forum_assert_can_create_topic()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.forum_can_create_topic(NEW.user_id, NEW.category_id) THEN
    IF public.forum_user_is_banned(NEW.user_id) THEN
      RAISE EXCEPTION 'forum_ban_active';
    ELSIF public.forum_user_is_silenced(NEW.user_id) THEN
      RAISE EXCEPTION 'forum_silence_active';
    ELSE
      RAISE EXCEPTION 'forum_topic_creation_not_allowed';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_assert_can_create_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.forum_can_create_post(NEW.user_id) THEN
    IF public.forum_user_is_banned(NEW.user_id) THEN
      RAISE EXCEPTION 'forum_ban_active';
    ELSIF public.forum_user_is_silenced(NEW.user_id) THEN
      RAISE EXCEPTION 'forum_silence_active';
    ELSIF public.forum_user_is_muted(NEW.user_id) THEN
      RAISE EXCEPTION 'forum_mute_active';
    ELSE
      RAISE EXCEPTION 'forum_post_creation_not_allowed';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_assert_can_create_topic ON public.forum_topics;
CREATE TRIGGER trg_forum_assert_can_create_topic
  BEFORE INSERT ON public.forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_assert_can_create_topic();

DROP TRIGGER IF EXISTS trg_forum_assert_can_create_post ON public.forum_posts;
CREATE TRIGGER trg_forum_assert_can_create_post
  BEFORE INSERT ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_assert_can_create_post();

DROP POLICY IF EXISTS "Authenticated users create topics" ON public.forum_topics;
CREATE POLICY "Authenticated users create topics" ON public.forum_topics
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND public.forum_can_create_topic(auth.uid(), category_id)
  );

DROP POLICY IF EXISTS "Authenticated users create posts" ON public.forum_posts;
CREATE POLICY "Authenticated users create posts" ON public.forum_posts
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND public.forum_can_create_post(auth.uid())
  );

DROP POLICY IF EXISTS "Users can view own bans" ON public.forum_user_bans;
CREATE POLICY "Users can view own bans" ON public.forum_user_bans
  FOR SELECT TO authenticated
  USING (
    auth.uid() = user_id
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Moderators can manage bans" ON public.forum_user_bans;
CREATE POLICY "Moderators can manage bans" ON public.forum_user_bans
  FOR INSERT TO authenticated
  WITH CHECK (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Moderators can update bans" ON public.forum_user_bans;
CREATE POLICY "Moderators can update bans" ON public.forum_user_bans
  FOR UPDATE TO authenticated
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Users can view own warning points" ON public.forum_warning_points;
CREATE POLICY "Users can view own warning points" ON public.forum_warning_points
  FOR SELECT TO authenticated
  USING (
    auth.uid() = user_id
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Users can see own warnings" ON public.forum_warnings;
DROP POLICY IF EXISTS "Users view own warnings" ON public.forum_warnings;
CREATE POLICY "Users view own warnings" ON public.forum_warnings
  FOR SELECT TO authenticated
  USING (
    auth.uid() = user_id
    OR public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Mods can manage warnings" ON public.forum_warnings;
DROP POLICY IF EXISTS "Mods create warnings" ON public.forum_warnings;
CREATE POLICY "Mods create warnings" ON public.forum_warnings
  FOR INSERT TO authenticated
  WITH CHECK (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Mods update warnings" ON public.forum_warnings;
CREATE POLICY "Mods update warnings" ON public.forum_warnings
  FOR UPDATE TO authenticated
  USING (
    public.has_role(auth.uid(), 'moderator')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DO $$
DECLARE
  v_user_id UUID;
BEGIN
  FOR v_user_id IN
    SELECT user_id FROM public.forum_user_stats
    UNION
    SELECT user_id FROM public.forum_user_bans
    UNION
    SELECT user_id FROM public.forum_warnings
  LOOP
    PERFORM public.forum_refresh_user_moderation_state(v_user_id);
  END LOOP;
END $$;
