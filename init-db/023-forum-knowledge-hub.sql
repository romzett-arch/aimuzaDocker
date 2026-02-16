-- ============================================================
-- FORUM KNOWLEDGE HUB — Intelligence Layer
-- Authority Engine + Knowledge Base + Economy + Semantic Clustering
-- Extends existing forum schema (30+ tables)
-- ============================================================

-- ============================================================
-- 1. AUTHORITY ENGINE — Quality-based user scoring
-- ============================================================

-- Extend forum_user_stats with authority columns
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS authority_score NUMERIC(8,2) DEFAULT 0;
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS authority_tier TEXT DEFAULT 'reader';
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS content_quality_avg NUMERIC(4,2) DEFAULT 0;
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS citations_received INTEGER DEFAULT 0;
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS mentorship_score INTEGER DEFAULT 0;
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS expertise_tags TEXT[] DEFAULT '{}';
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS can_create_articles BOOLEAN DEFAULT false;
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS can_boost_topics BOOLEAN DEFAULT false;
ALTER TABLE public.forum_user_stats ADD COLUMN IF NOT EXISTS authority_updated_at TIMESTAMPTZ DEFAULT now();

-- Content quality scores per topic/post
CREATE TABLE IF NOT EXISTS public.forum_content_quality (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content_type TEXT NOT NULL CHECK (content_type IN ('topic', 'post')),
  content_id UUID NOT NULL,
  author_id UUID NOT NULL,
  -- Quality metrics
  depth_score NUMERIC(4,2) DEFAULT 0,
  usefulness_score NUMERIC(4,2) DEFAULT 0,
  engagement_score NUMERIC(4,2) DEFAULT 0,
  uniqueness_score NUMERIC(4,2) DEFAULT 0,
  overall_quality NUMERIC(4,2) DEFAULT 0,
  -- Computed from
  word_count INTEGER DEFAULT 0,
  has_code_blocks BOOLEAN DEFAULT false,
  has_images BOOLEAN DEFAULT false,
  has_links BOOLEAN DEFAULT false,
  weighted_votes NUMERIC DEFAULT 0,
  solution_bonus NUMERIC DEFAULT 0,
  -- Meta
  computed_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(content_type, content_id)
);

CREATE INDEX IF NOT EXISTS idx_forum_cq_author ON public.forum_content_quality(author_id);
CREATE INDEX IF NOT EXISTS idx_forum_cq_quality ON public.forum_content_quality(overall_quality DESC);

-- ============================================================
-- 2. KNOWLEDGE BASE — Forum as structured repository
-- ============================================================

CREATE TABLE IF NOT EXISTS public.forum_knowledge_articles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_topic_id UUID REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  -- Content
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  content TEXT NOT NULL,
  content_html TEXT,
  -- Classification
  category TEXT NOT NULL DEFAULT 'guide',
  difficulty TEXT DEFAULT 'intermediate',
  tags TEXT[] DEFAULT '{}',
  expertise_area TEXT,
  -- Status
  status TEXT NOT NULL DEFAULT 'draft',
  is_featured BOOLEAN DEFAULT false,
  is_pinned BOOLEAN DEFAULT false,
  -- Author
  author_id UUID NOT NULL,
  curator_id UUID,
  curated_at TIMESTAMPTZ,
  -- Metrics
  views_count INTEGER DEFAULT 0,
  likes_count INTEGER DEFAULT 0,
  citations_count INTEGER DEFAULT 0,
  quality_score NUMERIC(4,2) DEFAULT 0,
  -- Meta
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  published_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_forum_kb_status ON public.forum_knowledge_articles(status);
CREATE INDEX IF NOT EXISTS idx_forum_kb_category ON public.forum_knowledge_articles(category);
CREATE INDEX IF NOT EXISTS idx_forum_kb_featured ON public.forum_knowledge_articles(is_featured) WHERE is_featured;
CREATE INDEX IF NOT EXISTS idx_forum_kb_quality ON public.forum_knowledge_articles(quality_score DESC);
CREATE INDEX IF NOT EXISTS idx_forum_kb_author ON public.forum_knowledge_articles(author_id);

-- Citations (topic/post references to articles)
CREATE TABLE IF NOT EXISTS public.forum_citations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  article_id UUID NOT NULL REFERENCES public.forum_knowledge_articles(id) ON DELETE CASCADE,
  citing_topic_id UUID REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  citing_post_id UUID REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  cited_by UUID NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(article_id, citing_topic_id),
  UNIQUE(article_id, citing_post_id)
);

-- ============================================================
-- 3. FORUM ECONOMY — Credit-based boost & premium
-- ============================================================

CREATE TABLE IF NOT EXISTS public.forum_topic_boosts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  boosted_by UUID NOT NULL,
  -- Boost params
  boost_type TEXT NOT NULL DEFAULT 'standard',
  credits_spent INTEGER NOT NULL DEFAULT 0,
  boost_multiplier NUMERIC(3,1) DEFAULT 1.5,
  -- Duration
  starts_at TIMESTAMPTZ DEFAULT now(),
  ends_at TIMESTAMPTZ NOT NULL,
  is_active BOOLEAN DEFAULT true,
  -- Meta
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_forum_boosts_topic ON public.forum_topic_boosts(topic_id);
CREATE INDEX IF NOT EXISTS idx_forum_boosts_active ON public.forum_topic_boosts(is_active, ends_at) WHERE is_active;

CREATE TABLE IF NOT EXISTS public.forum_premium_content (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  author_id UUID NOT NULL,
  -- Premium params
  price_credits INTEGER NOT NULL DEFAULT 0,
  preview_length INTEGER DEFAULT 500,
  is_active BOOLEAN DEFAULT true,
  -- Metrics
  purchases_count INTEGER DEFAULT 0,
  revenue_total INTEGER DEFAULT 0,
  -- Meta
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_content_purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL,
  price_paid INTEGER NOT NULL,
  purchased_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(topic_id, buyer_id)
);

-- ============================================================
-- 4. SEMANTIC CLUSTERING — Topic grouping & dedup
-- ============================================================

CREATE TABLE IF NOT EXISTS public.forum_topic_clusters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  category TEXT,
  topic_count INTEGER DEFAULT 0,
  avg_quality NUMERIC(4,2) DEFAULT 0,
  representative_topic_id UUID REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_topic_cluster_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_id UUID NOT NULL REFERENCES public.forum_topic_clusters(id) ON DELETE CASCADE,
  topic_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  similarity_score NUMERIC(4,3) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(cluster_id, topic_id)
);

CREATE TABLE IF NOT EXISTS public.forum_similar_topics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_a_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  topic_b_id UUID NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  similarity_score NUMERIC(4,3) NOT NULL,
  computed_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(topic_a_id, topic_b_id)
);

CREATE INDEX IF NOT EXISTS idx_forum_similar_a ON public.forum_similar_topics(topic_a_id);
CREATE INDEX IF NOT EXISTS idx_forum_similar_b ON public.forum_similar_topics(topic_b_id);
CREATE INDEX IF NOT EXISTS idx_forum_similar_score ON public.forum_similar_topics(similarity_score DESC);

-- Title trigram index for dedup
CREATE INDEX IF NOT EXISTS idx_forum_topics_title_trgm ON public.forum_topics USING gin (title gin_trgm_ops);

-- ============================================================
-- 5. HUB CONFIG
-- ============================================================

CREATE TABLE IF NOT EXISTS public.forum_hub_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  label TEXT,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 6. FUNCTIONS
-- ============================================================

-- Calculate content quality score
CREATE OR REPLACE FUNCTION public.forum_calculate_content_quality(
  p_content_type TEXT,
  p_content_id UUID
)
RETURNS NUMERIC AS $$
DECLARE
  v_content TEXT;
  v_author_id UUID;
  v_word_count INTEGER;
  v_depth NUMERIC := 0;
  v_usefulness NUMERIC := 0;
  v_engagement NUMERIC := 0;
  v_uniqueness NUMERIC := 0;
  v_overall NUMERIC := 0;
  v_votes_score INTEGER := 0;
  v_is_solution BOOLEAN := false;
  v_weighted_votes NUMERIC := 0;
  v_has_code BOOLEAN := false;
  v_has_images BOOLEAN := false;
  v_has_links BOOLEAN := false;
BEGIN
  IF p_content_type = 'topic' THEN
    SELECT content, user_id, votes_score, is_solved
      INTO v_content, v_author_id, v_votes_score, v_is_solution
      FROM public.forum_topics WHERE id = p_content_id;
  ELSIF p_content_type = 'post' THEN
    SELECT content, user_id, votes_score, is_solution
      INTO v_content, v_author_id, v_votes_score, v_is_solution
      FROM public.forum_posts WHERE id = p_content_id;
  END IF;

  IF v_content IS NULL THEN RETURN 0; END IF;

  -- Word count
  v_word_count := array_length(regexp_split_to_array(trim(v_content), '\s+'), 1);

  -- Depth score (0-10): based on length and structure
  v_depth := LEAST(10, (v_word_count::NUMERIC / 50.0) * 3
    + CASE WHEN v_content LIKE '%```%' THEN 2 ELSE 0 END
    + CASE WHEN v_content LIKE '%http%' THEN 1 ELSE 0 END
    + CASE WHEN v_content LIKE '%![%' THEN 1.5 ELSE 0 END
    + CASE WHEN v_word_count > 200 THEN 2 ELSE 0 END);

  v_has_code := v_content LIKE '%```%';
  v_has_images := v_content LIKE '%![%' OR v_content LIKE '%<img%';
  v_has_links := v_content LIKE '%http%';

  -- Usefulness (0-10): based on votes and solution status
  v_usefulness := LEAST(10, GREATEST(0, v_votes_score) * 2
    + CASE WHEN v_is_solution THEN 5 ELSE 0 END);

  -- Weighted votes (high-authority voters count more)
  SELECT COALESCE(SUM(
    CASE WHEN fus.authority_score > 50 THEN 2.0
         WHEN fus.authority_score > 20 THEN 1.5
         ELSE 1.0 END
  ), 0) INTO v_weighted_votes
  FROM public.forum_post_votes fpv
  LEFT JOIN public.forum_user_stats fus ON fus.user_id = fpv.user_id
  WHERE (p_content_type = 'post' AND fpv.post_id = p_content_id)
     OR (p_content_type = 'topic' AND fpv.topic_id = p_content_id);

  -- Engagement (0-10)
  v_engagement := LEAST(10, v_weighted_votes * 1.5);

  -- Uniqueness placeholder (would need NLP in production)
  v_uniqueness := LEAST(10, v_depth * 0.5 + CASE WHEN v_has_code THEN 2 ELSE 0 END);

  -- Overall quality (weighted average)
  v_overall := ROUND((v_depth * 0.3 + v_usefulness * 0.35 + v_engagement * 0.2 + v_uniqueness * 0.15)::NUMERIC, 2);

  -- Upsert quality record
  INSERT INTO public.forum_content_quality (content_type, content_id, author_id,
    depth_score, usefulness_score, engagement_score, uniqueness_score, overall_quality,
    word_count, has_code_blocks, has_images, has_links, weighted_votes,
    solution_bonus, computed_at)
  VALUES (p_content_type, p_content_id, v_author_id,
    v_depth, v_usefulness, v_engagement, v_uniqueness, v_overall,
    v_word_count, v_has_code, v_has_images, v_has_links, v_weighted_votes,
    CASE WHEN v_is_solution THEN 5 ELSE 0 END, now())
  ON CONFLICT (content_type, content_id) DO UPDATE SET
    depth_score = EXCLUDED.depth_score,
    usefulness_score = EXCLUDED.usefulness_score,
    engagement_score = EXCLUDED.engagement_score,
    uniqueness_score = EXCLUDED.uniqueness_score,
    overall_quality = EXCLUDED.overall_quality,
    word_count = EXCLUDED.word_count,
    has_code_blocks = EXCLUDED.has_code_blocks,
    has_images = EXCLUDED.has_images,
    has_links = EXCLUDED.has_links,
    weighted_votes = EXCLUDED.weighted_votes,
    solution_bonus = EXCLUDED.solution_bonus,
    computed_at = now();

  RETURN v_overall;
END;
$$ LANGUAGE plpgsql;

-- Recalculate user authority
CREATE OR REPLACE FUNCTION public.forum_recalculate_authority(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_quality_avg NUMERIC;
  v_solutions INTEGER;
  v_citations INTEGER;
  v_score NUMERIC;
  v_tier TEXT;
  v_can_articles BOOLEAN;
  v_can_boost BOOLEAN;
  v_expertise TEXT[];
BEGIN
  -- Average content quality
  SELECT COALESCE(AVG(overall_quality), 0) INTO v_quality_avg
    FROM public.forum_content_quality WHERE author_id = p_user_id;

  -- Solutions count
  SELECT COALESCE(solutions_count, 0) INTO v_solutions
    FROM public.forum_user_stats WHERE user_id = p_user_id;

  -- Citations
  SELECT COUNT(*) INTO v_citations
    FROM public.forum_citations c
    JOIN public.forum_knowledge_articles a ON a.id = c.article_id
    WHERE a.author_id = p_user_id;

  -- Expertise tags (top tags by quality)
  SELECT COALESCE(array_agg(t.name ORDER BY cq.overall_quality DESC), '{}')
    INTO v_expertise
    FROM (
      SELECT DISTINCT unnest(ft.tags) AS tag_name, ft.id AS topic_id
      FROM public.forum_topics ft WHERE ft.user_id = p_user_id AND ft.tags IS NOT NULL
    ) tagged
    JOIN public.forum_tags t ON t.name = tagged.tag_name
    JOIN public.forum_content_quality cq ON cq.content_id = tagged.topic_id AND cq.content_type = 'topic'
    LIMIT 5;

  -- Authority score
  v_score := ROUND((
    v_quality_avg * 10
    + v_solutions * 5
    + v_citations * 3
    + COALESCE((SELECT reputation_score FROM public.forum_user_stats WHERE user_id = p_user_id), 0) * 0.1
  )::NUMERIC, 2);

  -- Authority tier
  v_tier := CASE
    WHEN v_score >= 200 THEN 'moderator'
    WHEN v_score >= 100 THEN 'mentor'
    WHEN v_score >= 30 THEN 'contributor'
    ELSE 'reader'
  END;

  v_can_articles := v_score >= 50;
  v_can_boost := v_score >= 20;

  -- Update user stats
  UPDATE public.forum_user_stats SET
    authority_score = v_score,
    authority_tier = v_tier,
    content_quality_avg = v_quality_avg,
    citations_received = v_citations,
    expertise_tags = v_expertise,
    can_create_articles = v_can_articles,
    can_boost_topics = v_can_boost,
    authority_updated_at = now()
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'score', v_score, 'tier', v_tier,
    'quality_avg', v_quality_avg, 'solutions', v_solutions,
    'citations', v_citations, 'expertise', v_expertise
  );
END;
$$ LANGUAGE plpgsql;

-- Find similar forum topics
CREATE OR REPLACE FUNCTION public.forum_find_similar_topics(
  p_title TEXT,
  p_category_id UUID DEFAULT NULL,
  p_threshold NUMERIC DEFAULT 0.25,
  p_limit INTEGER DEFAULT 5
)
RETURNS TABLE(
  id UUID, title TEXT, slug TEXT, category_id UUID,
  status TEXT, votes_score INTEGER, is_solved BOOLEAN,
  similarity NUMERIC, created_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT t.id, t.title, t.slug, t.category_id,
    CASE WHEN t.is_hidden THEN 'hidden' WHEN t.is_locked THEN 'locked' ELSE 'active' END,
    t.votes_score, t.is_solved,
    ROUND(similarity(t.title, p_title)::NUMERIC, 3),
    t.created_at
  FROM public.forum_topics t
  WHERE similarity(t.title, p_title) > p_threshold
    AND NOT t.is_hidden
    AND (p_category_id IS NULL OR t.category_id = p_category_id)
  ORDER BY similarity(t.title, p_title) DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Boost a topic
CREATE OR REPLACE FUNCTION public.forum_boost_topic(
  p_topic_id UUID,
  p_boost_type TEXT DEFAULT 'standard',
  p_duration_hours INTEGER DEFAULT 24
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_cost INTEGER;
  v_multiplier NUMERIC;
  v_balance INTEGER;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  -- Determine cost
  v_cost := CASE p_boost_type
    WHEN 'standard' THEN 5
    WHEN 'premium' THEN 15
    WHEN 'mega' THEN 30
    ELSE 5 END;
  v_multiplier := CASE p_boost_type
    WHEN 'standard' THEN 1.5
    WHEN 'premium' THEN 3.0
    WHEN 'mega' THEN 5.0
    ELSE 1.5 END;

  -- Check balance (from profiles.credits)
  SELECT COALESCE(credits, 0) INTO v_balance FROM public.profiles WHERE user_id = v_user_id;
  IF v_balance < v_cost THEN
    RETURN jsonb_build_object('success', false, 'error', 'Insufficient credits', 'required', v_cost, 'balance', v_balance);
  END IF;

  -- Deduct credits
  UPDATE public.profiles SET credits = credits - v_cost WHERE user_id = v_user_id;

  -- Create boost
  INSERT INTO public.forum_topic_boosts (topic_id, boosted_by, boost_type, credits_spent, boost_multiplier, ends_at)
    VALUES (p_topic_id, v_user_id, p_boost_type, v_cost, v_multiplier, now() + (p_duration_hours || ' hours')::INTERVAL);

  -- Bump topic
  UPDATE public.forum_topics SET bumped_at = now() WHERE id = p_topic_id;

  RETURN jsonb_build_object('success', true, 'cost', v_cost, 'multiplier', v_multiplier, 'hours', p_duration_hours);
END;
$$ LANGUAGE plpgsql;

-- Get knowledge base stats
CREATE OR REPLACE FUNCTION public.forum_get_hub_stats()
RETURNS JSONB AS $$
DECLARE v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total_articles', (SELECT COUNT(*) FROM public.forum_knowledge_articles WHERE status = 'published'),
    'draft_articles', (SELECT COUNT(*) FROM public.forum_knowledge_articles WHERE status = 'draft'),
    'total_citations', (SELECT COUNT(*) FROM public.forum_citations),
    'active_boosts', (SELECT COUNT(*) FROM public.forum_topic_boosts WHERE is_active AND ends_at > now()),
    'total_boost_revenue', (SELECT COALESCE(SUM(credits_spent), 0) FROM public.forum_topic_boosts),
    'avg_content_quality', (SELECT ROUND(COALESCE(AVG(overall_quality), 0)::NUMERIC, 2) FROM public.forum_content_quality),
    'high_quality_count', (SELECT COUNT(*) FROM public.forum_content_quality WHERE overall_quality >= 7),
    'mentors_count', (SELECT COUNT(*) FROM public.forum_user_stats WHERE authority_tier = 'mentor'),
    'moderators_count', (SELECT COUNT(*) FROM public.forum_user_stats WHERE authority_tier = 'moderator'),
    'contributors_count', (SELECT COUNT(*) FROM public.forum_user_stats WHERE authority_tier = 'contributor'),
    'clusters_count', (SELECT COUNT(*) FROM public.forum_topic_clusters),
    'premium_content', (SELECT COUNT(*) FROM public.forum_premium_content WHERE is_active)
  ) INTO v_result;
  RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

-- Get authority leaderboard
CREATE OR REPLACE FUNCTION public.forum_authority_leaderboard(p_limit INTEGER DEFAULT 20)
RETURNS TABLE(
  user_id UUID, username TEXT, avatar_url TEXT,
  authority_score NUMERIC, authority_tier TEXT,
  content_quality_avg NUMERIC, solutions_count INTEGER,
  citations_received INTEGER, expertise_tags TEXT[]
) AS $$
BEGIN
  RETURN QUERY
  SELECT s.user_id, p.username, p.avatar_url,
    s.authority_score, s.authority_tier,
    s.content_quality_avg, s.solutions_count,
    s.citations_received, s.expertise_tags
  FROM public.forum_user_stats s
  LEFT JOIN public.profiles p ON p.user_id = s.user_id
  WHERE s.authority_score > 0
  ORDER BY s.authority_score DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- 7. RLS POLICIES
-- ============================================================

ALTER TABLE public.forum_content_quality ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_knowledge_articles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_citations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topic_boosts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_premium_content ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_content_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topic_clusters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topic_cluster_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_similar_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_hub_config ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 8. SEED DATA
-- ============================================================

INSERT INTO public.forum_hub_config (key, value, label, description) VALUES
  ('authority', '{"reader_min": 0, "contributor_min": 30, "mentor_min": 100, "moderator_min": 200, "recalc_interval_hours": 6, "vote_weight_reader": 1.0, "vote_weight_contributor": 1.5, "vote_weight_mentor": 2.0, "vote_weight_moderator": 3.0}',
   'Authority Engine', 'Tier thresholds and vote weights'),
  ('knowledge_base', '{"auto_promote_quality_min": 8.0, "min_word_count_article": 200, "article_categories": ["guide","tutorial","case-study","prompt-engineering","mixing","mastering","theory","news"], "difficulty_levels": ["beginner","intermediate","advanced","expert"]}',
   'Knowledge Base', 'Article promotion and categorization'),
  ('economy', '{"boost_standard_cost": 5, "boost_premium_cost": 15, "boost_mega_cost": 30, "boost_standard_hours": 24, "boost_premium_hours": 72, "boost_mega_hours": 168, "premium_min_authority": 50, "author_revenue_share": 0.7}',
   'Forum Economy', 'Boost costs and premium content'),
  ('semantic', '{"similarity_threshold": 0.25, "max_similar_topics": 5, "cluster_min_topics": 3, "auto_suggest_on_create": true}',
   'Semantic Intelligence', 'Clustering and deduplication'),
  ('quality', '{"min_quality_for_kb": 7.0, "quality_weights": {"depth": 0.3, "usefulness": 0.35, "engagement": 0.2, "uniqueness": 0.15}, "solution_bonus": 5, "code_block_bonus": 2, "image_bonus": 1.5, "link_bonus": 1}',
   'Content Quality', 'Quality scoring parameters')
ON CONFLICT (key) DO NOTHING;
