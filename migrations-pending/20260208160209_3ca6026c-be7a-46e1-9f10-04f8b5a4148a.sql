
-- Table for tracking when users last read a category or topic
CREATE TABLE public.forum_user_reads (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('category', 'topic')),
  entity_id UUID NOT NULL,
  last_read_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, entity_type, entity_id)
);

-- Index for efficient lookups by user
CREATE INDEX idx_forum_user_reads_user ON public.forum_user_reads(user_id);
CREATE INDEX idx_forum_user_reads_entity ON public.forum_user_reads(entity_type, entity_id);

-- Enable RLS
ALTER TABLE public.forum_user_reads ENABLE ROW LEVEL SECURITY;

-- Users can see only their own reads
CREATE POLICY "Users can view their own reads"
ON public.forum_user_reads
FOR SELECT
USING (auth.uid() = user_id);

-- Users can insert their own reads
CREATE POLICY "Users can insert their own reads"
ON public.forum_user_reads
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Users can update their own reads
CREATE POLICY "Users can update their own reads"
ON public.forum_user_reads
FOR UPDATE
USING (auth.uid() = user_id);

-- Upsert function for marking as read
CREATE OR REPLACE FUNCTION public.forum_mark_read(
  p_user_id UUID,
  p_entity_type TEXT,
  p_entity_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.forum_user_reads (user_id, entity_type, entity_id, last_read_at)
  VALUES (p_user_id, p_entity_type, p_entity_id, now())
  ON CONFLICT (user_id, entity_type, entity_id)
  DO UPDATE SET last_read_at = now();
END;
$$;
