-- Add parent_id to forum_categories for subforums support
ALTER TABLE public.forum_categories 
ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES public.forum_categories(id) ON DELETE SET NULL;

-- Index for fast parent_id lookups (filtering subcategories)
CREATE INDEX IF NOT EXISTS idx_forum_categories_parent_id 
ON public.forum_categories(parent_id) WHERE parent_id IS NOT NULL;
