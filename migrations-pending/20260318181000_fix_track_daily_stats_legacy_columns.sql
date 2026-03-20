-- Приводим legacy-схему track_daily_stats к текущему контракту *_count.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'plays'
  ) AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'plays_count'
  ) THEN
    ALTER TABLE public.track_daily_stats RENAME COLUMN plays TO plays_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'likes'
  ) AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'likes_count'
  ) THEN
    ALTER TABLE public.track_daily_stats RENAME COLUMN likes TO likes_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'shares'
  ) AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'shares_count'
  ) THEN
    ALTER TABLE public.track_daily_stats RENAME COLUMN shares TO shares_count;
  END IF;
END $$;

ALTER TABLE public.track_daily_stats
  ADD COLUMN IF NOT EXISTS plays_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS likes_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS shares_count INTEGER DEFAULT 0;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'plays'
  ) THEN
    EXECUTE '
      UPDATE public.track_daily_stats
      SET plays_count = COALESCE(plays_count, 0) + COALESCE(plays, 0)
      WHERE COALESCE(plays, 0) <> 0
    ';
    ALTER TABLE public.track_daily_stats DROP COLUMN plays;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'likes'
  ) THEN
    EXECUTE '
      UPDATE public.track_daily_stats
      SET likes_count = COALESCE(likes_count, 0) + COALESCE(likes, 0)
      WHERE COALESCE(likes, 0) <> 0
    ';
    ALTER TABLE public.track_daily_stats DROP COLUMN likes;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'track_daily_stats'
      AND column_name = 'shares'
  ) THEN
    EXECUTE '
      UPDATE public.track_daily_stats
      SET shares_count = COALESCE(shares_count, 0) + COALESCE(shares, 0)
      WHERE COALESCE(shares, 0) <> 0
    ';
    ALTER TABLE public.track_daily_stats DROP COLUMN shares;
  END IF;
END $$;

UPDATE public.track_daily_stats
SET
  plays_count = COALESCE(plays_count, 0),
  likes_count = COALESCE(likes_count, 0),
  shares_count = COALESCE(shares_count, 0)
WHERE plays_count IS NULL
   OR likes_count IS NULL
   OR shares_count IS NULL;

ALTER TABLE public.track_daily_stats
  ALTER COLUMN plays_count SET DEFAULT 0,
  ALTER COLUMN likes_count SET DEFAULT 0,
  ALTER COLUMN shares_count SET DEFAULT 0;
