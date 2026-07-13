-- Forum Knowledge Hub: enforce a real role model for standard PostgREST clients.
-- The custom API also applies equivalent application-level scoping because it
-- connects as the database owner and therefore bypasses RLS.

CREATE UNIQUE INDEX IF NOT EXISTS uq_forum_kb_source_topic
  ON public.forum_knowledge_articles(source_topic_id)
  WHERE source_topic_id IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_kb_status_check') THEN
    ALTER TABLE public.forum_knowledge_articles
      ADD CONSTRAINT forum_kb_status_check CHECK (status IN ('draft', 'published', 'archived'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'forum_kb_difficulty_check') THEN
    ALTER TABLE public.forum_knowledge_articles
      ADD CONSTRAINT forum_kb_difficulty_check CHECK (difficulty IN ('beginner', 'intermediate', 'advanced', 'expert'));
  END IF;
END $$;

ALTER TABLE public.forum_knowledge_articles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_hub_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_citations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Published knowledge is public" ON public.forum_knowledge_articles;
CREATE POLICY "Published knowledge is public"
  ON public.forum_knowledge_articles FOR SELECT
  USING (
    status = 'published'
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Admins manage knowledge" ON public.forum_knowledge_articles;
CREATE POLICY "Admins manage knowledge"
  ON public.forum_knowledge_articles FOR ALL
  USING (
    public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Admins manage forum hub config" ON public.forum_hub_config;
CREATE POLICY "Admins manage forum hub config"
  ON public.forum_hub_config FOR ALL
  USING (
    public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

DROP POLICY IF EXISTS "Citations are public" ON public.forum_citations;
CREATE POLICY "Citations are public"
  ON public.forum_citations FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users create own citations" ON public.forum_citations;
CREATE POLICY "Users create own citations"
  ON public.forum_citations FOR INSERT
  WITH CHECK (auth.uid() = cited_by);

DROP POLICY IF EXISTS "Users delete own citations" ON public.forum_citations;
CREATE POLICY "Users delete own citations"
  ON public.forum_citations FOR DELETE
  USING (
    auth.uid() = cited_by
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'super_admin')
  );

GRANT SELECT ON public.forum_knowledge_articles TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.forum_knowledge_articles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.forum_hub_config TO authenticated;
GRANT SELECT ON public.forum_citations TO anon, authenticated;
GRANT INSERT, DELETE ON public.forum_citations TO authenticated;
