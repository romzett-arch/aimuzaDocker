ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS email_last_changed_at timestamptz DEFAULT NULL;