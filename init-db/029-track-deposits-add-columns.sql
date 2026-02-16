-- Добавляем недостающие колонки в track_deposits (миграция с 006-audit на полную схему)
ALTER TABLE public.track_deposits
  ADD COLUMN IF NOT EXISTS file_hash TEXT,
  ADD COLUMN IF NOT EXISTS metadata_hash TEXT,
  ADD COLUMN IF NOT EXISTS certificate_url TEXT,
  ADD COLUMN IF NOT EXISTS blockchain_tx_id TEXT,
  ADD COLUMN IF NOT EXISTS external_deposit_id TEXT,
  ADD COLUMN IF NOT EXISTS external_certificate_url TEXT,
  ADD COLUMN IF NOT EXISTS error_message TEXT,
  ADD COLUMN IF NOT EXISTS performer_name TEXT,
  ADD COLUMN IF NOT EXISTS lyrics_author TEXT;

-- Для существующих строк — placeholder, чтобы можно было добавить NOT NULL
UPDATE public.track_deposits SET file_hash = 'legacy' WHERE file_hash IS NULL;

-- Делаем file_hash обязательным для новых записей
ALTER TABLE public.track_deposits ALTER COLUMN file_hash SET NOT NULL;

-- Уникальность: один метод на трек (игнорируем если уже есть)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'track_deposits_track_id_method_key'
    AND conrelid = 'public.track_deposits'::regclass
  ) THEN
    ALTER TABLE public.track_deposits ADD CONSTRAINT track_deposits_track_id_method_key UNIQUE (track_id, method);
  END IF;
EXCEPTION
  WHEN unique_violation THEN NULL; -- дубликаты — пропускаем
END $$;
