BEGIN;

-- Reconcile the legacy forum schema with the current client contract. Forum
-- reputation is stored in forum_user_stats.reputation; reputation_score stays
-- reserved for the unified site-wide reputation system.

ALTER TABLE public.forum_user_stats
  ADD COLUMN IF NOT EXISTS topics_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS posts_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reputation integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS topics_created integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS posts_created integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reputation_score integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS likes_given integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS likes_received integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS solutions_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS warnings_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS trust_level integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_silenced boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS silenced_until timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.forum_reputation_config
  ADD COLUMN IF NOT EXISTS action text,
  ADD COLUMN IF NOT EXISTS points integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS trust_level integer,
  ADD COLUMN IF NOT EXISTS min_reputation integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS label text,
  ADD COLUMN IF NOT EXISTS label_ru text,
  ADD COLUMN IF NOT EXISTS color text NOT NULL DEFAULT '#888',
  ADD COLUMN IF NOT EXISTS icon text,
  ADD COLUMN IF NOT EXISTS max_likes_per_day integer,
  ADD COLUMN IF NOT EXISTS max_topics_per_day integer,
  ADD COLUMN IF NOT EXISTS max_posts_per_day integer,
  ADD COLUMN IF NOT EXISTS can_downvote boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_upload_files boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_use_reactions boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_edit_wiki boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_retag boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_move_topics boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.forum_reputation_config ALTER COLUMN action DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS forum_reputation_config_trust_level_key
  ON public.forum_reputation_config(trust_level)
  WHERE trust_level IS NOT NULL;

INSERT INTO public.forum_reputation_config (
  trust_level, min_reputation, label, label_ru, color, icon,
  max_likes_per_day, max_topics_per_day, max_posts_per_day,
  can_downvote, can_upload_files, can_use_reactions
)
VALUES
  (0, 0,    'Newcomer', 'Новичок',    '#888888', NULL,     10,   1,   5,   false, false, false),
  (1, 50,   'Member',   'Участник',   '#3B82F6', 'Star',   30,   5,   30,  false, true,  true),
  (2, 200,  'Regular',  'Активный',   '#22C55E', 'Award',  100,  20,  100, true,  true,  true),
  (3, 500,  'Leader',   'Лидер',      '#A855F7', 'Crown',  NULL, NULL, NULL, true, true,  true),
  (4, 1000, 'Elder',    'Старейшина', '#F97316', 'Shield', NULL, NULL, NULL, true, true,  true)
ON CONFLICT (trust_level) WHERE trust_level IS NOT NULL DO UPDATE SET
  min_reputation = EXCLUDED.min_reputation,
  label = EXCLUDED.label,
  label_ru = EXCLUDED.label_ru,
  color = EXCLUDED.color,
  icon = EXCLUDED.icon,
  max_likes_per_day = EXCLUDED.max_likes_per_day,
  max_topics_per_day = EXCLUDED.max_topics_per_day,
  max_posts_per_day = EXCLUDED.max_posts_per_day,
  can_downvote = EXCLUDED.can_downvote,
  can_upload_files = EXCLUDED.can_upload_files,
  can_use_reactions = EXCLUDED.can_use_reactions;

ALTER TABLE public.forum_reputation_log
  ADD COLUMN IF NOT EXISTS action text,
  ADD COLUMN IF NOT EXISTS points integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS delta integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reason text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS source_type text NOT NULL DEFAULT 'legacy',
  ADD COLUMN IF NOT EXISTS source_id uuid,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.forum_reputation_log ALTER COLUMN action DROP NOT NULL;
UPDATE public.forum_reputation_log
SET delta = CASE WHEN delta = 0 THEN COALESCE(points, 0) ELSE delta END,
    reason = CASE WHEN reason = '' THEN COALESCE(action, 'Изменение репутации') ELSE reason END;

CREATE INDEX IF NOT EXISTS idx_forum_rep_log_user
  ON public.forum_reputation_log(user_id, created_at DESC);

-- Votes and reactions must support both posts and topics.
DO $$
DECLARE
  v_constraint record;
BEGIN
  FOR v_constraint IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.forum_post_votes'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%vote_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.forum_post_votes DROP CONSTRAINT %I', v_constraint.conname);
  END LOOP;
END;
$$;

ALTER TABLE public.forum_post_votes ALTER COLUMN vote_type DROP DEFAULT;
ALTER TABLE public.forum_post_votes
  ALTER COLUMN vote_type TYPE smallint
  USING CASE lower(vote_type::text)
    WHEN 'up' THEN 1
    WHEN 'upvote' THEN 1
    WHEN '1' THEN 1
    WHEN 'down' THEN -1
    WHEN 'downvote' THEN -1
    WHEN '-1' THEN -1
    ELSE 1
  END;
ALTER TABLE public.forum_post_votes ALTER COLUMN vote_type SET NOT NULL;
ALTER TABLE public.forum_post_votes ADD COLUMN IF NOT EXISTS topic_id uuid;
ALTER TABLE public.forum_post_reactions ADD COLUMN IF NOT EXISTS topic_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_post_votes_topic_id_fkey') THEN
    ALTER TABLE public.forum_post_votes
      ADD CONSTRAINT forum_post_votes_topic_id_fkey
      FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_post_reactions_topic_id_fkey') THEN
    ALTER TABLE public.forum_post_reactions
      ADD CONSTRAINT forum_post_reactions_topic_id_fkey
      FOREIGN KEY (topic_id) REFERENCES public.forum_topics(id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_post_votes_vote_type_check') THEN
    ALTER TABLE public.forum_post_votes
      ADD CONSTRAINT forum_post_votes_vote_type_check CHECK (vote_type IN (-1, 1));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_post_votes_target_check') THEN
    ALTER TABLE public.forum_post_votes
      ADD CONSTRAINT forum_post_votes_target_check CHECK (
        (post_id IS NOT NULL AND topic_id IS NULL)
        OR (post_id IS NULL AND topic_id IS NOT NULL)
      );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_post_reactions_target_check') THEN
    ALTER TABLE public.forum_post_reactions
      ADD CONSTRAINT forum_post_reactions_target_check CHECK (
        (post_id IS NOT NULL AND topic_id IS NULL)
        OR (post_id IS NULL AND topic_id IS NOT NULL)
      );
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS forum_post_votes_topic_user_key
  ON public.forum_post_votes(topic_id, user_id) WHERE topic_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS forum_post_reactions_topic_user_emoji_key
  ON public.forum_post_reactions(topic_id, user_id, emoji) WHERE topic_id IS NOT NULL;

-- Rebuild counters and the dedicated forum score from authoritative content.
INSERT INTO public.forum_user_stats(user_id)
SELECT user_id FROM (
  SELECT user_id FROM public.forum_topics
  UNION SELECT user_id FROM public.forum_posts
  UNION SELECT user_id FROM public.forum_post_votes
  UNION SELECT user_id FROM public.forum_post_reactions
) users
WHERE user_id IS NOT NULL
ON CONFLICT (user_id) DO NOTHING;

UPDATE public.forum_topics t
SET votes_score = COALESCE((
  SELECT sum(v.vote_type)::integer FROM public.forum_post_votes v WHERE v.topic_id = t.id
), 0);

UPDATE public.forum_posts p
SET votes_score = COALESCE((
  SELECT sum(v.vote_type)::integer FROM public.forum_post_votes v WHERE v.post_id = p.id
), 0);

UPDATE public.forum_user_stats s
SET topics_created = (SELECT count(*)::integer FROM public.forum_topics t WHERE t.user_id = s.user_id),
    topics_count = (SELECT count(*)::integer FROM public.forum_topics t WHERE t.user_id = s.user_id),
    posts_created = (SELECT count(*)::integer FROM public.forum_posts p WHERE p.user_id = s.user_id),
    posts_count = (SELECT count(*)::integer FROM public.forum_posts p WHERE p.user_id = s.user_id),
    likes_received =
      (SELECT count(*)::integer FROM public.forum_post_votes v JOIN public.forum_posts p ON p.id = v.post_id WHERE p.user_id = s.user_id AND v.vote_type = 1 AND v.user_id <> p.user_id)
      + (SELECT count(*)::integer FROM public.forum_post_votes v JOIN public.forum_topics t ON t.id = v.topic_id WHERE t.user_id = s.user_id AND v.vote_type = 1 AND v.user_id <> t.user_id),
    likes_given = (SELECT count(*)::integer FROM public.forum_post_votes v WHERE v.user_id = s.user_id AND v.vote_type = 1),
    solutions_count = (SELECT count(*)::integer FROM public.forum_posts p WHERE p.user_id = s.user_id AND p.is_solution),
    reputation = GREATEST(0,
      2 * (SELECT count(*)::integer FROM public.forum_topics t WHERE t.user_id = s.user_id)
      + (SELECT count(*)::integer FROM public.forum_posts p WHERE p.user_id = s.user_id)
      + COALESCE((SELECT sum(CASE v.vote_type WHEN 1 THEN 5 ELSE -2 END)::integer FROM public.forum_post_votes v JOIN public.forum_posts p ON p.id = v.post_id WHERE p.user_id = s.user_id AND v.user_id <> p.user_id), 0)
      + COALESCE((SELECT sum(CASE v.vote_type WHEN 1 THEN 5 ELSE -2 END)::integer FROM public.forum_post_votes v JOIN public.forum_topics t ON t.id = v.topic_id WHERE t.user_id = s.user_id AND v.user_id <> t.user_id), 0)
      + (SELECT count(*)::integer FROM public.forum_post_reactions r JOIN public.forum_posts p ON p.id = r.post_id WHERE p.user_id = s.user_id AND r.user_id <> p.user_id)
      + (SELECT count(*)::integer FROM public.forum_post_reactions r JOIN public.forum_topics t ON t.id = r.topic_id WHERE t.user_id = s.user_id AND r.user_id <> t.user_id)
      + 15 * (SELECT count(*)::integer FROM public.forum_posts p JOIN public.forum_topics t ON t.id = p.topic_id WHERE p.user_id = s.user_id AND p.is_solution AND p.user_id <> t.user_id)
    ),
    last_post_at = (SELECT max(p.created_at) FROM public.forum_posts p WHERE p.user_id = s.user_id),
    updated_at = now();

UPDATE public.forum_user_stats s
SET trust_level = GREATEST(
      COALESCE(s.trust_level, 0),
      COALESCE((SELECT max(c.trust_level) FROM public.forum_reputation_config c WHERE c.trust_level IS NOT NULL AND c.min_reputation <= s.reputation), 0)
    ),
    updated_at = now();

DELETE FROM public.forum_reputation_log WHERE source_type = 'migration_rebuild';
INSERT INTO public.forum_reputation_log(user_id, delta, reason, source_type)
SELECT user_id, reputation, 'Пересчёт форумной репутации по фактической активности', 'migration_rebuild'
FROM public.forum_user_stats
WHERE reputation <> 0;

CREATE OR REPLACE FUNCTION public.forum_award_reputation(
  p_user_id uuid,
  p_delta integer,
  p_reason text,
  p_source_type text,
  p_source_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_score integer;
  v_new_score integer;
  v_applied_delta integer;
  v_new_level integer;
BEGIN
  IF p_user_id IS NULL OR p_delta = 0 THEN RETURN; END IF;

  INSERT INTO public.forum_user_stats(user_id, reputation)
  VALUES (p_user_id, GREATEST(0, p_delta))
  ON CONFLICT (user_id) DO NOTHING;

  SELECT reputation INTO v_old_score
  FROM public.forum_user_stats
  WHERE user_id = p_user_id
  FOR UPDATE;

  v_new_score := GREATEST(0, COALESCE(v_old_score, 0) + p_delta);
  v_applied_delta := v_new_score - COALESCE(v_old_score, 0);

  SELECT COALESCE(max(trust_level), 0) INTO v_new_level
  FROM public.forum_reputation_config
  WHERE trust_level IS NOT NULL AND min_reputation <= v_new_score;

  UPDATE public.forum_user_stats
  SET reputation = v_new_score,
      trust_level = GREATEST(COALESCE(trust_level, 0), v_new_level),
      updated_at = now()
  WHERE user_id = p_user_id;

  IF v_applied_delta <> 0 THEN
    INSERT INTO public.forum_reputation_log(user_id, delta, reason, source_type, source_id)
    VALUES (p_user_id, v_applied_delta, p_reason, p_source_type, p_source_id);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_update_user_stats_on_topic()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := CASE WHEN TG_OP = 'INSERT' THEN NEW.user_id ELSE OLD.user_id END;
  v_delta integer := CASE WHEN TG_OP = 'INSERT' THEN 1 ELSE -1 END;
BEGIN
  INSERT INTO public.forum_user_stats(user_id) VALUES (v_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.forum_user_stats
  SET topics_created = GREATEST(0, topics_created + v_delta),
      topics_count = GREATEST(0, topics_count + v_delta),
      updated_at = now()
  WHERE user_id = v_user_id;
  PERFORM public.forum_award_reputation(
    v_user_id, 2 * v_delta,
    CASE WHEN TG_OP = 'INSERT' THEN 'Создание темы' ELSE 'Удаление темы' END,
    'topic_created', CASE WHEN TG_OP = 'INSERT' THEN NEW.id ELSE OLD.id END
  );
  RETURN CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_update_user_stats_on_post()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := CASE WHEN TG_OP = 'INSERT' THEN NEW.user_id ELSE OLD.user_id END;
  v_delta integer := CASE WHEN TG_OP = 'INSERT' THEN 1 ELSE -1 END;
  v_topic_author uuid;
BEGIN
  INSERT INTO public.forum_user_stats(user_id) VALUES (v_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.forum_user_stats
  SET posts_created = GREATEST(0, posts_created + v_delta),
      posts_count = GREATEST(0, posts_count + v_delta),
      solutions_count = GREATEST(0, solutions_count + CASE WHEN TG_OP = 'DELETE' AND OLD.is_solution THEN -1 ELSE 0 END),
      last_post_at = CASE WHEN TG_OP = 'INSERT' THEN NEW.created_at ELSE last_post_at END,
      updated_at = now()
  WHERE user_id = v_user_id;
  PERFORM public.forum_award_reputation(
    v_user_id, v_delta,
    CASE WHEN TG_OP = 'INSERT' THEN 'Ответ в теме' ELSE 'Удаление ответа' END,
    'post_created', CASE WHEN TG_OP = 'INSERT' THEN NEW.id ELSE OLD.id END
  );
  IF TG_OP = 'DELETE' AND OLD.is_solution THEN
    SELECT user_id INTO v_topic_author FROM public.forum_topics WHERE id = OLD.topic_id;
    IF v_topic_author IS DISTINCT FROM OLD.user_id THEN
      PERFORM public.forum_award_reputation(OLD.user_id, -15, 'Решение удалено', 'solution', OLD.id);
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_topic_reputation ON public.forum_topics;
DROP TRIGGER IF EXISTS trg_forum_post_reputation ON public.forum_posts;
DROP TRIGGER IF EXISTS trg_forum_user_stats_topic ON public.forum_topics;
DROP TRIGGER IF EXISTS trg_forum_user_stats_post ON public.forum_posts;
CREATE TRIGGER trg_forum_user_stats_topic
AFTER INSERT OR DELETE ON public.forum_topics
FOR EACH ROW EXECUTE FUNCTION public.forum_update_user_stats_on_topic();
CREATE TRIGGER trg_forum_user_stats_post
AFTER INSERT OR DELETE ON public.forum_posts
FOR EACH ROW EXECUTE FUNCTION public.forum_update_user_stats_on_post();

CREATE OR REPLACE FUNCTION public.forum_on_vote_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author_id uuid;
  v_voter_id uuid := COALESCE(NEW.user_id, OLD.user_id);
  v_post_id uuid := COALESCE(NEW.post_id, OLD.post_id);
  v_topic_id uuid := COALESCE(NEW.topic_id, OLD.topic_id);
  v_old_vote integer := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN OLD.vote_type ELSE 0 END;
  v_new_vote integer := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN NEW.vote_type ELSE 0 END;
  v_old_points integer;
  v_new_points integer;
  v_upvote_delta integer;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.user_id, NEW.post_id, NEW.topic_id) IS DISTINCT FROM (OLD.user_id, OLD.post_id, OLD.topic_id) THEN
    RAISE EXCEPTION 'Нельзя менять цель или автора голоса';
  END IF;

  IF v_post_id IS NOT NULL THEN
    SELECT user_id INTO v_author_id FROM public.forum_posts WHERE id = v_post_id;
  ELSE
    SELECT user_id INTO v_author_id FROM public.forum_topics WHERE id = v_topic_id;
  END IF;
  IF v_author_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  IF v_author_id = v_voter_id THEN RAISE EXCEPTION 'Нельзя голосовать за собственную публикацию'; END IF;

  v_old_points := CASE v_old_vote WHEN 1 THEN 5 WHEN -1 THEN -2 ELSE 0 END;
  v_new_points := CASE v_new_vote WHEN 1 THEN 5 WHEN -1 THEN -2 ELSE 0 END;
  v_upvote_delta := (CASE WHEN v_new_vote = 1 THEN 1 ELSE 0 END) - (CASE WHEN v_old_vote = 1 THEN 1 ELSE 0 END);

  IF v_post_id IS NOT NULL THEN
    UPDATE public.forum_posts SET votes_score = COALESCE(votes_score, 0) + v_new_vote - v_old_vote WHERE id = v_post_id;
  ELSE
    UPDATE public.forum_topics SET votes_score = COALESCE(votes_score, 0) + v_new_vote - v_old_vote WHERE id = v_topic_id;
  END IF;

  INSERT INTO public.forum_user_stats(user_id) VALUES (v_author_id), (v_voter_id)
  ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.forum_user_stats
  SET likes_received = GREATEST(0, likes_received + v_upvote_delta), updated_at = now()
  WHERE user_id = v_author_id;
  UPDATE public.forum_user_stats
  SET likes_given = GREATEST(0, likes_given + v_upvote_delta), updated_at = now()
  WHERE user_id = v_voter_id;

  PERFORM public.forum_award_reputation(
    v_author_id, v_new_points - v_old_points,
    CASE
      WHEN TG_OP = 'DELETE' THEN 'Голос отменён'
      WHEN TG_OP = 'UPDATE' THEN 'Голос изменён'
      WHEN v_new_vote = 1 THEN 'Получен upvote'
      ELSE 'Получен downvote'
    END,
    'vote', COALESCE(NEW.id, OLD.id)
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_reputation_vote ON public.forum_post_votes;
DROP TRIGGER IF EXISTS trg_forum_vote_reputation ON public.forum_post_votes;
CREATE TRIGGER trg_forum_vote_reputation
AFTER INSERT OR UPDATE OF vote_type OR DELETE ON public.forum_post_votes
FOR EACH ROW EXECUTE FUNCTION public.forum_on_vote_reputation();

CREATE OR REPLACE FUNCTION public.forum_on_reaction_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_author_id uuid;
  v_actor_id uuid := COALESCE(NEW.user_id, OLD.user_id);
  v_post_id uuid := COALESCE(NEW.post_id, OLD.post_id);
  v_topic_id uuid := COALESCE(NEW.topic_id, OLD.topic_id);
  v_delta integer := CASE WHEN TG_OP = 'INSERT' THEN 1 ELSE -1 END;
BEGIN
  IF v_post_id IS NOT NULL THEN
    SELECT user_id INTO v_author_id FROM public.forum_posts WHERE id = v_post_id;
  ELSE
    SELECT user_id INTO v_author_id FROM public.forum_topics WHERE id = v_topic_id;
  END IF;
  IF v_author_id IS NOT NULL AND v_author_id <> v_actor_id THEN
    PERFORM public.forum_award_reputation(
      v_author_id, v_delta,
      CASE WHEN TG_OP = 'INSERT' THEN 'Получена реакция' ELSE 'Реакция снята' END,
      'reaction', COALESCE(NEW.id, OLD.id)
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_forum_reaction_reputation ON public.forum_post_reactions;
CREATE TRIGGER trg_forum_reaction_reputation
AFTER INSERT OR DELETE ON public.forum_post_reactions
FOR EACH ROW EXECUTE FUNCTION public.forum_on_reaction_reputation();

CREATE OR REPLACE FUNCTION public.forum_mark_solution(p_post_id uuid, p_topic_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_topic_author uuid;
  v_new_author uuid;
  v_old_post_id uuid;
  v_old_author uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Необходимо войти в систему'; END IF;
  SELECT user_id, solved_post_id INTO v_topic_author, v_old_post_id
  FROM public.forum_topics WHERE id = p_topic_id FOR UPDATE;
  IF v_topic_author IS NULL THEN RAISE EXCEPTION 'Тема не найдена'; END IF;
  IF v_actor <> v_topic_author AND NOT (
    public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin') OR public.has_role(v_actor, 'moderator')
  ) THEN RAISE EXCEPTION 'Только автор темы или модератор может выбрать решение'; END IF;

  SELECT user_id INTO v_new_author
  FROM public.forum_posts
  WHERE id = p_post_id AND topic_id = p_topic_id AND NOT is_hidden;
  IF v_new_author IS NULL THEN RAISE EXCEPTION 'Ответ не найден в этой теме'; END IF;
  IF v_old_post_id = p_post_id THEN RETURN; END IF;

  IF v_old_post_id IS NOT NULL THEN
    SELECT user_id INTO v_old_author FROM public.forum_posts WHERE id = v_old_post_id;
    UPDATE public.forum_posts SET is_solution = false WHERE id = v_old_post_id;
    IF v_old_author IS NOT NULL THEN
      UPDATE public.forum_user_stats SET solutions_count = GREATEST(0, solutions_count - 1), updated_at = now() WHERE user_id = v_old_author;
      IF v_old_author <> v_topic_author THEN
        PERFORM public.forum_award_reputation(v_old_author, -15, 'Решение заменено', 'solution', v_old_post_id);
      END IF;
    END IF;
  ELSE
    UPDATE public.forum_posts SET is_solution = false WHERE topic_id = p_topic_id AND is_solution;
  END IF;

  UPDATE public.forum_posts SET is_solution = true WHERE id = p_post_id;
  UPDATE public.forum_topics SET is_solved = true, solved_post_id = p_post_id, updated_at = now() WHERE id = p_topic_id;
  INSERT INTO public.forum_user_stats(user_id, solutions_count) VALUES (v_new_author, 1)
  ON CONFLICT (user_id) DO UPDATE SET solutions_count = forum_user_stats.solutions_count + 1, updated_at = now();
  IF v_new_author <> v_topic_author THEN
    PERFORM public.forum_award_reputation(v_new_author, 15, 'Ответ отмечен как решение', 'solution', p_post_id);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_get_user_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats public.forum_user_stats%ROWTYPE;
  v_config public.forum_reputation_config%ROWTYPE;
  v_next public.forum_reputation_config%ROWTYPE;
BEGIN
  SELECT * INTO v_stats FROM public.forum_user_stats WHERE user_id = p_user_id;
  IF NOT FOUND THEN
    v_stats.user_id := p_user_id;
    v_stats.reputation := 0;
    v_stats.trust_level := 0;
    v_stats.topics_created := 0;
    v_stats.posts_created := 0;
    v_stats.likes_given := 0;
    v_stats.likes_received := 0;
    v_stats.solutions_count := 0;
    v_stats.warnings_count := 0;
    v_stats.is_silenced := false;
  END IF;
  SELECT * INTO v_config FROM public.forum_reputation_config WHERE trust_level = COALESCE(v_stats.trust_level, 0);
  SELECT * INTO v_next FROM public.forum_reputation_config WHERE trust_level > COALESCE(v_stats.trust_level, 0) ORDER BY trust_level LIMIT 1;

  RETURN jsonb_build_object(
    'user_id', p_user_id,
    'reputation_score', COALESCE(v_stats.reputation, 0),
    'trust_level', COALESCE(v_stats.trust_level, 0),
    'trust_label', COALESCE(v_config.label_ru, 'Новичок'),
    'trust_color', COALESCE(v_config.color, '#888888'),
    'trust_icon', v_config.icon,
    'topics_created', COALESCE(v_stats.topics_created, 0),
    'posts_created', COALESCE(v_stats.posts_created, 0),
    'likes_given', COALESCE(v_stats.likes_given, 0),
    'likes_received', COALESCE(v_stats.likes_received, 0),
    'solutions_count', COALESCE(v_stats.solutions_count, 0),
    'warnings_count', COALESCE(v_stats.warnings_count, 0),
    'is_silenced', COALESCE(v_stats.is_silenced, false),
    'silenced_until', v_stats.silenced_until,
    'can_downvote', COALESCE(v_config.can_downvote, false),
    'can_upload_files', COALESCE(v_config.can_upload_files, false),
    'can_use_reactions', COALESCE(v_config.can_use_reactions, false),
    'next_level_rep', v_next.min_reputation,
    'next_level_label', v_next.label_ru,
    'progress_to_next', CASE
      WHEN v_next.trust_level IS NULL THEN 100
      ELSE LEAST(100, GREATEST(0, round(
        ((COALESCE(v_stats.reputation, 0) - COALESCE(v_config.min_reputation, 0))::numeric /
        GREATEST(v_next.min_reputation - COALESCE(v_config.min_reputation, 0), 1)) * 100
      )))
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_get_users_profiles(p_user_ids uuid[])
RETURNS TABLE(
  user_id uuid, reputation_score integer, trust_level integer, trust_label text,
  trust_color text, trust_icon text, topics_created integer, posts_created integer,
  likes_given integer, likes_received integer, solutions_count integer, warnings_count integer,
  is_silenced boolean, silenced_until timestamptz, can_downvote boolean,
  can_upload_files boolean, can_use_reactions boolean, next_level_rep integer,
  next_level_label text, progress_to_next integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ids AS (SELECT DISTINCT unnest(COALESCE(p_user_ids, ARRAY[]::uuid[])) AS user_id)
  SELECT ids.user_id,
    COALESCE(s.reputation, 0), COALESCE(s.trust_level, 0), COALESCE(c.label_ru, 'Новичок'),
    COALESCE(c.color, '#888888'), c.icon, COALESCE(s.topics_created, 0), COALESCE(s.posts_created, 0),
    COALESCE(s.likes_given, 0), COALESCE(s.likes_received, 0), COALESCE(s.solutions_count, 0), COALESCE(s.warnings_count, 0),
    COALESCE(s.is_silenced, false), s.silenced_until, COALESCE(c.can_downvote, false),
    COALESCE(c.can_upload_files, false), COALESCE(c.can_use_reactions, false), n.min_reputation, n.label_ru,
    CASE WHEN n.trust_level IS NULL THEN 100 ELSE LEAST(100, GREATEST(0, round(
      ((COALESCE(s.reputation, 0) - COALESCE(c.min_reputation, 0))::numeric /
      GREATEST(n.min_reputation - COALESCE(c.min_reputation, 0), 1)) * 100
    )))::integer END
  FROM ids
  LEFT JOIN public.forum_user_stats s ON s.user_id = ids.user_id
  LEFT JOIN public.forum_reputation_config c ON c.trust_level = COALESCE(s.trust_level, 0)
  LEFT JOIN LATERAL (
    SELECT nc.* FROM public.forum_reputation_config nc
    WHERE nc.trust_level > COALESCE(s.trust_level, 0)
    ORDER BY nc.trust_level LIMIT 1
  ) n ON true;
$$;

DROP FUNCTION IF EXISTS public.forum_get_leaderboard(integer);

CREATE OR REPLACE FUNCTION public.forum_get_leaderboard(p_limit integer DEFAULT 20)
RETURNS TABLE(user_id uuid, username text, avatar_url text, reputation_score integer, trust_level integer, topics_created integer, posts_created integer, solutions_count integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.user_id, p.username, p.avatar_url, COALESCE(s.reputation, 0), COALESCE(s.trust_level, 0),
    COALESCE(s.topics_created, 0), COALESCE(s.posts_created, 0), COALESCE(s.solutions_count, 0)
  FROM public.forum_user_stats s
  LEFT JOIN public.profiles_public p ON p.user_id = s.user_id
  WHERE s.reputation > 0
  ORDER BY s.reputation DESC, s.updated_at ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
$$;

CREATE OR REPLACE FUNCTION public.forum_admin_list_users(
  p_search text DEFAULT '', p_filter text DEFAULT 'all', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0
)
RETURNS TABLE(
  user_id uuid, username text, avatar_url text, trust_level integer, reputation_score integer,
  topics_created integer, posts_created integer, warnings_count integer, is_muted boolean,
  muted_until timestamptz, is_silenced boolean, silenced_until timestamptz, is_banned boolean,
  banned_until timestamptz, ban_reason text, created_at timestamptz, last_post_at timestamptz, total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL OR NOT (public.has_role(v_actor, 'admin') OR public.has_role(v_actor, 'super_admin')) THEN RAISE EXCEPTION 'Недостаточно прав'; END IF;
  IF p_filter NOT IN ('all', 'muted', 'banned', 'warned') THEN RAISE EXCEPTION 'Некорректный фильтр'; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 OR p_offset < 0 THEN RAISE EXCEPTION 'Некорректная пагинация'; END IF;
  RETURN QUERY
  SELECT s.user_id, p.username, p.avatar_url, COALESCE(s.trust_level, 0), COALESCE(s.reputation, 0),
    COALESCE(s.topics_created, 0), COALESCE(s.posts_created, 0), COALESCE(s.warnings_count, 0),
    COALESCE(s.is_muted, false), s.muted_until, COALESCE(s.is_silenced, false), s.silenced_until,
    COALESCE(s.is_banned, false), s.banned_until, s.ban_reason, s.joined_at, s.last_post_at, count(*) OVER ()
  FROM public.forum_user_stats s
  LEFT JOIN public.profiles_public p ON p.user_id = s.user_id
  WHERE (trim(COALESCE(p_search, '')) = '' OR p.username ILIKE '%' || trim(p_search) || '%')
    AND (p_filter = 'all' OR (p_filter = 'muted' AND s.is_muted) OR (p_filter = 'banned' AND s.is_banned) OR (p_filter = 'warned' AND s.warnings_count > 0))
  ORDER BY s.reputation DESC, s.joined_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

-- Least-privilege access. Public reads go through SECURITY DEFINER RPCs;
-- authenticated clients may only write their own votes/reactions.
DO $$
DECLARE
  v_table text;
  v_policy record;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['forum_user_stats','forum_reputation_config','forum_reputation_log','forum_post_votes','forum_post_reactions']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_table);
    FOR v_policy IN SELECT policyname FROM pg_policies WHERE schemaname = 'public' AND tablename = v_table
    LOOP
      EXECUTE format('DROP POLICY %I ON public.%I', v_policy.policyname, v_table);
    END LOOP;
  END LOOP;
END;
$$;

CREATE POLICY forum_user_stats_read ON public.forum_user_stats FOR SELECT TO authenticated USING (true);
CREATE POLICY forum_user_stats_admin_update ON public.forum_user_stats FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));
CREATE POLICY forum_reputation_config_read ON public.forum_reputation_config FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY forum_reputation_config_admin_update ON public.forum_reputation_config FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));
CREATE POLICY forum_reputation_log_own_read ON public.forum_reputation_log FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'super_admin'));
CREATE POLICY forum_post_votes_read ON public.forum_post_votes FOR SELECT TO authenticated USING (true);
CREATE POLICY forum_post_votes_insert_own ON public.forum_post_votes FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY forum_post_votes_update_own ON public.forum_post_votes FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY forum_post_votes_delete_own ON public.forum_post_votes FOR DELETE TO authenticated USING (user_id = auth.uid());
CREATE POLICY forum_post_reactions_read ON public.forum_post_reactions FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY forum_post_reactions_insert_own ON public.forum_post_reactions FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY forum_post_reactions_delete_own ON public.forum_post_reactions FOR DELETE TO authenticated USING (user_id = auth.uid());

REVOKE ALL ON public.forum_user_stats, public.forum_reputation_config, public.forum_reputation_log, public.forum_post_votes, public.forum_post_reactions FROM anon, authenticated;
GRANT SELECT ON public.forum_reputation_config, public.forum_post_reactions TO anon;
GRANT SELECT ON public.forum_user_stats, public.forum_reputation_config, public.forum_reputation_log, public.forum_post_votes, public.forum_post_reactions TO authenticated;
GRANT UPDATE ON public.forum_user_stats, public.forum_reputation_config TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.forum_post_votes TO authenticated;
GRANT INSERT, DELETE ON public.forum_post_reactions TO authenticated;

REVOKE ALL ON FUNCTION public.forum_award_reputation(uuid, integer, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.forum_award_reputation(uuid, integer, text, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.forum_mark_solution(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.forum_mark_solution(uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.forum_get_user_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_get_user_profile(uuid) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.forum_get_users_profiles(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_get_users_profiles(uuid[]) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.forum_get_leaderboard(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forum_get_leaderboard(integer) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.forum_admin_list_users(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.forum_admin_list_users(text, text, integer, integer) TO authenticated, service_role;

COMMIT;
