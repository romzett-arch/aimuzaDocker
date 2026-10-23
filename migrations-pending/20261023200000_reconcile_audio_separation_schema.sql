-- Keep the shared vocal-separation workflow compatible with databases that
-- still have the original 2026 table constraints.  The runtime uses `vocal`
-- and `price_rub`; callbacks also use the transient `refunding` status.

ALTER TABLE public.audio_separations
  ADD COLUMN IF NOT EXISTS price_rub integer NOT NULL DEFAULT 0;

DO $$
DECLARE
  has_legacy_price boolean;
  constraint_name text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'audio_separations'
      AND column_name = 'price_aipci'
  ) INTO has_legacy_price;

  IF has_legacy_price THEN
    EXECUTE 'UPDATE public.audio_separations
             SET price_rub = GREATEST(COALESCE(price_rub, 0), COALESCE(price_aipci, 0))';
  END IF;

  FOR constraint_name IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.audio_separations'::regclass
      AND contype = 'c'
      AND (
        pg_get_constraintdef(oid) ILIKE '%type%'
        OR pg_get_constraintdef(oid) ILIKE '%status%'
      )
  LOOP
    EXECUTE format('ALTER TABLE public.audio_separations DROP CONSTRAINT %I', constraint_name);
  END LOOP;
END
$$;

COMMENT ON COLUMN public.audio_separations.price_rub IS
  'Amount charged for vocal separation in rubles.';
