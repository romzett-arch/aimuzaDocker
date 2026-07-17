-- Restore columns expected by the current forum browsing UI on legacy databases.

BEGIN;

ALTER TABLE public.forum_topics
  ADD COLUMN IF NOT EXISTS solved_post_id uuid,
  ADD COLUMN IF NOT EXISTS last_post_id uuid,
  ADD COLUMN IF NOT EXISTS edited_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.forum_topics'::regclass
      AND conname = 'forum_topics_solved_post_id_fkey'
  ) THEN
    ALTER TABLE public.forum_topics
      ADD CONSTRAINT forum_topics_solved_post_id_fkey
      FOREIGN KEY (solved_post_id)
      REFERENCES public.forum_posts(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.forum_topics'::regclass
      AND conname = 'forum_topics_last_post_id_fkey'
  ) THEN
    ALTER TABLE public.forum_topics
      ADD CONSTRAINT forum_topics_last_post_id_fkey
      FOREIGN KEY (last_post_id)
      REFERENCES public.forum_posts(id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

ALTER TABLE public.forum_category_subscriptions
  ADD COLUMN IF NOT EXISTS level text;

UPDATE public.forum_category_subscriptions
SET level = 'watching'
WHERE level IS NULL;

ALTER TABLE public.forum_category_subscriptions
  ALTER COLUMN level SET DEFAULT 'watching',
  ALTER COLUMN level SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.forum_category_subscriptions'::regclass
      AND conname = 'forum_category_subscriptions_level_check'
  ) THEN
    ALTER TABLE public.forum_category_subscriptions
      ADD CONSTRAINT forum_category_subscriptions_level_check
      CHECK (level IN ('watching', 'tracking', 'muted'));
  END IF;
END;
$$;

ALTER TABLE public.forum_reputation_config
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

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'forum_reputation_config'
      AND column_name = 'action'
  ) THEN
    ALTER TABLE public.forum_reputation_config
      ALTER COLUMN action DROP NOT NULL;
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS forum_reputation_config_trust_level_key
  ON public.forum_reputation_config(trust_level)
  WHERE trust_level IS NOT NULL;

INSERT INTO public.forum_reputation_config (
  trust_level,
  min_reputation,
  label,
  label_ru,
  color,
  icon,
  max_likes_per_day,
  max_topics_per_day,
  max_posts_per_day,
  can_downvote,
  can_upload_files,
  can_use_reactions
)
VALUES
  (0, 0,    'Newcomer', 'Новичок',    '#888888', NULL,     10,   1,   5,   false, false, false),
  (1, 50,   'Member',   'Участник',   '#3B82F6', 'Star',   30,   5,   30,  false, true,  true),
  (2, 200,  'Regular',  'Активный',   '#22C55E', 'Award',  100,  20,  100, true,  true,  true),
  (3, 500,  'Leader',   'Лидер',      '#A855F7', 'Crown',  NULL, NULL, NULL, true,  true,  true),
  (4, 1000, 'Elder',    'Старейшина', '#F97316', 'Shield', NULL, NULL, NULL, true,  true,  true)
ON CONFLICT (trust_level) WHERE trust_level IS NOT NULL DO NOTHING;

COMMIT;
