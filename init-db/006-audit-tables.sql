-- ═══════════════════════════════════════════════════════════════════
-- AUDIT: Все недостающие таблицы, views и RPC-функции
-- Запускать ПОСЛЕ 001..005 скриптов
-- ═══════════════════════════════════════════════════════════════════

-- ── profiles_public VIEW ─────────────────────────────────────────
CREATE OR REPLACE VIEW public.profiles_public AS
SELECT
  id, user_id, username, avatar_url, cover_url, bio,
  social_links, followers_count, following_count,
  display_name, created_at, updated_at
FROM public.profiles;

-- ── Расширение profiles: email_unsubscribed ──────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='email_unsubscribed') THEN
    ALTER TABLE public.profiles ADD COLUMN email_unsubscribed boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='short_id') THEN
    ALTER TABLE public.profiles ADD COLUMN short_id text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='last_seen_at') THEN
    ALTER TABLE public.profiles ADD COLUMN last_seen_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='xp') THEN
    ALTER TABLE public.profiles ADD COLUMN xp integer DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='level') THEN
    ALTER TABLE public.profiles ADD COLUMN level integer DEFAULT 1;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='trust_level') THEN
    ALTER TABLE public.profiles ADD COLUMN trust_level integer DEFAULT 0;
  END IF;
END $$;


-- ═══════════════════════════════════════════════════════════════════
-- ADVERTISING TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.ad_creatives (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid,
  type text DEFAULT 'image',
  title text,
  description text,
  media_url text,
  click_url text,
  cta_text text,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ad_slots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slot_type text NOT NULL,
  description text,
  width integer,
  height integer,
  is_active boolean DEFAULT true,
  base_price numeric DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ad_campaign_slots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  slot_id uuid REFERENCES public.ad_slots(id) ON DELETE CASCADE,
  priority integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ad_targeting (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid REFERENCES public.ad_campaigns(id) ON DELETE CASCADE,
  target_type text,
  target_value text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ad_impressions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid REFERENCES public.ad_campaigns(id) ON DELETE SET NULL,
  creative_id uuid REFERENCES public.ad_creatives(id) ON DELETE SET NULL,
  slot_id uuid,
  user_id uuid,
  ip_address text,
  is_click boolean DEFAULT false,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- ADMIN / SYSTEM TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.admin_emails (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid,
  sender_type text DEFAULT 'project',
  recipient_id uuid,
  recipient_email text,
  subject text,
  body_html text,
  template_id uuid,
  status text DEFAULT 'pending',
  error_message text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.email_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE,
  subject text,
  body_html text,
  variables jsonb DEFAULT '[]'::jsonb,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.announcement_dismissals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_id uuid REFERENCES public.admin_announcements(id) ON DELETE CASCADE,
  user_id uuid,
  dismissed_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_provider_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  api_key_encrypted text,
  base_url text,
  model_name text,
  settings jsonb DEFAULT '{}'::jsonb,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  name text NOT NULL,
  key_hash text NOT NULL,
  prefix text,
  permissions jsonb DEFAULT '[]'::jsonb,
  expires_at timestamptz,
  last_used_at timestamptz,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.error_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  level text DEFAULT 'error',
  message text,
  stack text,
  context jsonb DEFAULT '{}'::jsonb,
  user_id uuid,
  url text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.performance_alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  metric text,
  value numeric,
  threshold numeric,
  severity text DEFAULT 'warning',
  context jsonb DEFAULT '{}'::jsonb,
  resolved boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.legal_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL,
  title text NOT NULL,
  content text,
  version text,
  is_active boolean DEFAULT true,
  published_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.bug_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  title text,
  description text,
  steps_to_reproduce text,
  expected_behavior text,
  actual_behavior text,
  severity text DEFAULT 'medium',
  status text DEFAULT 'open',
  screenshot_url text,
  browser_info jsonb DEFAULT '{}'::jsonb,
  assigned_to uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.impersonation_action_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid,
  target_user_id uuid,
  action text,
  details jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- MEDIA / CONTENT TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.gallery_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  type text DEFAULT 'image',
  title text,
  description text,
  url text,
  thumbnail_url text,
  prompt text,
  style text,
  track_id uuid,
  is_public boolean DEFAULT false,
  likes_count integer DEFAULT 0,
  views_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.audio_separations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  track_id uuid,
  type text DEFAULT 'vocal',
  status text DEFAULT 'pending',
  source_url text,
  result_urls jsonb,
  error_message text,
  price_rub integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.generated_lyrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  prompt text,
  lyrics text,
  title text,
  genre text,
  mood text,
  language text DEFAULT 'ru',
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.copyright_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  track_id uuid,
  type text DEFAULT 'copyright',
  status text DEFAULT 'pending',
  description text,
  evidence_urls jsonb DEFAULT '[]'::jsonb,
  response text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.distribution_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid,
  user_id uuid,
  platform text,
  status text DEFAULT 'pending',
  external_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  error_message text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.track_daily_stats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid,
  date date NOT NULL DEFAULT CURRENT_DATE,
  plays integer DEFAULT 0,
  likes integer DEFAULT 0,
  downloads integer DEFAULT 0,
  shares integer DEFAULT 0,
  comments integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE(track_id, date)
);

CREATE TABLE IF NOT EXISTS public.track_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid,
  user_id uuid,
  vote_type text DEFAULT 'like',
  created_at timestamptz DEFAULT now(),
  UNIQUE(track_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.internal_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid,
  user_id uuid,
  vote text,
  comment text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.track_deposits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  track_id uuid,
  amount integer DEFAULT 0,
  status text DEFAULT 'pending',
  payment_id uuid,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.track_promotions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid,
  user_id uuid,
  type text DEFAULT 'boost',
  status text DEFAULT 'active',
  amount integer DEFAULT 0,
  impressions integer DEFAULT 0,
  clicks integer DEFAULT 0,
  starts_at timestamptz DEFAULT now(),
  ends_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.lyrics_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  title text,
  content text,
  genre text,
  mood text,
  tags text[],
  price integer DEFAULT 0,
  is_public boolean DEFAULT false,
  downloads_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.lyrics_deposits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  lyrics_item_id uuid,
  amount integer DEFAULT 0,
  status text DEFAULT 'pending',
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- STORE / MARKETPLACE TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.store_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  type text DEFAULT 'digital',
  title text NOT NULL,
  description text,
  price integer DEFAULT 0,
  cover_url text,
  file_url text,
  category text,
  tags text[],
  is_active boolean DEFAULT true,
  sales_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.item_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid REFERENCES public.store_items(id) ON DELETE SET NULL,
  buyer_id uuid,
  seller_id uuid,
  price integer DEFAULT 0,
  status text DEFAULT 'completed',
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.prompt_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id uuid,
  prompt_id uuid,
  seller_id uuid,
  price integer DEFAULT 0,
  payment_id uuid,
  status text DEFAULT 'completed',
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- COMMENTS / INTERACTIONS
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.comment_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid,
  user_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(comment_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.comment_mentions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid,
  mentioned_user_id uuid,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.comment_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid,
  user_id uuid,
  emoji text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.comment_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid,
  user_id uuid,
  reason text,
  status text DEFAULT 'pending',
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- BALANCE / FINANCIAL
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.balance_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  amount integer NOT NULL,
  type text NOT NULL,
  description text,
  reference_type text,
  reference_id uuid,
  balance_before integer DEFAULT 0,
  balance_after integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  plan_id uuid,
  status text DEFAULT 'active',
  period_type text DEFAULT 'monthly',
  current_period_start timestamptz DEFAULT now(),
  current_period_end timestamptz,
  canceled_at timestamptz,
  payment_id uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- CONTEST EXTENDED TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.contest_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id uuid,
  entry_id uuid,
  user_id uuid,
  score integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE(entry_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.contest_jury (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id uuid,
  user_id uuid,
  role text DEFAULT 'jury',
  created_at timestamptz DEFAULT now(),
  UNIQUE(contest_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.contest_jury_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id uuid,
  entry_id uuid,
  jury_id uuid,
  score numeric DEFAULT 0,
  feedback text,
  criteria_scores jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.contest_comment_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid,
  user_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(comment_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.contest_asset_downloads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id uuid,
  user_id uuid,
  asset_url text,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- ACHIEVEMENTS / GAMIFICATION
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  name_ru text,
  description text,
  icon text,
  category text DEFAULT 'general',
  xp_reward integer DEFAULT 0,
  condition_type text,
  condition_value integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  achievement_id uuid REFERENCES public.achievements(id) ON DELETE CASCADE,
  unlocked_at timestamptz DEFAULT now(),
  UNIQUE(user_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS public.user_streaks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE,
  current_streak integer DEFAULT 0,
  longest_streak integer DEFAULT 0,
  last_activity_date date,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  type text DEFAULT 'daily',
  xp_reward integer DEFAULT 0,
  condition_type text,
  condition_value integer DEFAULT 0,
  is_active boolean DEFAULT true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  challenge_id uuid REFERENCES public.challenges(id) ON DELETE CASCADE,
  progress integer DEFAULT 0,
  completed boolean DEFAULT false,
  completed_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.feature_trials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  feature text NOT NULL,
  uses_remaining integer DEFAULT 0,
  total_uses integer DEFAULT 0,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICATION / SECURITY
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.verification_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  type text DEFAULT 'artist',
  status text DEFAULT 'pending',
  real_name text,
  social_links jsonb DEFAULT '[]'::jsonb,
  documents jsonb DEFAULT '[]'::jsonb,
  notes text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.security_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  action text,
  ip_address text,
  user_agent text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- REFERRAL EXTENDED TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.referral_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  value text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.referral_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  code text UNIQUE NOT NULL,
  uses_count integer DEFAULT 0,
  max_uses integer,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.referral_rewards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_id uuid,
  user_id uuid,
  type text DEFAULT 'bonus',
  amount integer DEFAULT 0,
  status text DEFAULT 'pending',
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.referral_stats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE,
  total_referrals integer DEFAULT 0,
  active_referrals integer DEFAULT 0,
  total_earned integer DEFAULT 0,
  updated_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- FORUM EXTENDED TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.forum_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text UNIQUE NOT NULL,
  slug text UNIQUE,
  color text DEFAULT '#888',
  description text,
  usage_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_topic_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  tag_id uuid REFERENCES public.forum_tags(id) ON DELETE CASCADE,
  UNIQUE(topic_id, tag_id)
);

CREATE TABLE IF NOT EXISTS public.forum_post_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  user_id uuid,
  vote_type text DEFAULT 'up',
  created_at timestamptz DEFAULT now(),
  UNIQUE(post_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.forum_post_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  user_id uuid,
  emoji text NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(post_id, user_id, emoji)
);

CREATE TABLE IF NOT EXISTS public.forum_bookmarks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

CREATE TABLE IF NOT EXISTS public.forum_topic_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

CREATE TABLE IF NOT EXISTS public.forum_category_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  category_id uuid REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, category_id)
);

CREATE TABLE IF NOT EXISTS public.forum_user_reads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  topic_id uuid,
  last_read_post_id uuid,
  last_read_at timestamptz DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

CREATE TABLE IF NOT EXISTS public.forum_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid,
  target_type text NOT NULL,
  target_id uuid NOT NULL,
  reason text NOT NULL,
  details text,
  status text DEFAULT 'pending',
  moderator_id uuid,
  resolution text,
  created_at timestamptz DEFAULT now(),
  resolved_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.forum_user_stats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE,
  topics_count integer DEFAULT 0,
  posts_count integer DEFAULT 0,
  likes_received integer DEFAULT 0,
  likes_given integer DEFAULT 0,
  reputation integer DEFAULT 0,
  solutions_count integer DEFAULT 0,
  warnings_count integer DEFAULT 0,
  trust_level integer DEFAULT 0,
  joined_at timestamptz DEFAULT now(),
  last_post_at timestamptz,
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_warnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  moderator_id uuid,
  reason text NOT NULL,
  severity text DEFAULT 'warning',
  points integer DEFAULT 1,
  expires_at timestamptz,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_mod_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  moderator_id uuid,
  action text NOT NULL,
  target_type text,
  target_id uuid,
  reason text,
  details jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  topic_id uuid,
  category_id uuid,
  title text,
  content text,
  is_reply boolean DEFAULT false,
  parent_post_id uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid,
  user_id uuid,
  file_url text NOT NULL,
  file_name text,
  file_size integer,
  mime_type text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  question text NOT NULL,
  allow_multiple boolean DEFAULT false,
  anonymous boolean DEFAULT false,
  expires_at timestamptz,
  total_votes integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_poll_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid REFERENCES public.forum_polls(id) ON DELETE CASCADE,
  text text NOT NULL,
  votes_count integer DEFAULT 0,
  sort_order integer DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.forum_poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid REFERENCES public.forum_polls(id) ON DELETE CASCADE,
  option_id uuid REFERENCES public.forum_poll_options(id) ON DELETE CASCADE,
  user_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(poll_id, option_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.forum_reputation_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text UNIQUE NOT NULL,
  points integer DEFAULT 0,
  description text,
  is_active boolean DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.forum_reputation_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  action text,
  points integer DEFAULT 0,
  source_type text,
  source_id uuid,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_automod_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_type text NOT NULL,
  pattern text,
  action text DEFAULT 'flag',
  severity text DEFAULT 'low',
  is_active boolean DEFAULT true,
  settings jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_promo_slots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid,
  user_id uuid,
  slot_type text DEFAULT 'featured',
  position integer DEFAULT 0,
  starts_at timestamptz DEFAULT now(),
  ends_at timestamptz,
  is_active boolean DEFAULT true,
  price integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_staff_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  author_id uuid,
  note text NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_warning_points (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  points integer DEFAULT 0,
  reason text,
  issued_by uuid,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_warning_appeals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  warning_id uuid,
  user_id uuid,
  reason text NOT NULL,
  status text DEFAULT 'pending',
  moderator_id uuid,
  resolution text,
  created_at timestamptz DEFAULT now(),
  resolved_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.forum_user_bans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  banned_by uuid,
  reason text NOT NULL,
  ban_type text DEFAULT 'temporary',
  expires_at timestamptz,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  action text NOT NULL,
  target_type text,
  target_id uuid,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_read_status (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  topic_id uuid,
  last_read_at timestamptz DEFAULT now(),
  UNIQUE(user_id, topic_id)
);

CREATE TABLE IF NOT EXISTS public.forum_user_ignores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  ignored_user_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, ignored_user_id)
);

CREATE TABLE IF NOT EXISTS public.forum_link_previews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  url text UNIQUE NOT NULL,
  title text,
  description text,
  image_url text,
  site_name text,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- OTHER MISSING TABLES
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.generation_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  type text DEFAULT 'music',
  prompt text,
  settings jsonb DEFAULT '{}'::jsonb,
  status text DEFAULT 'queued',
  position integer DEFAULT 0,
  priority integer DEFAULT 0,
  track_id uuid,
  error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.track_health_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid,
  check_type text,
  status text DEFAULT 'ok',
  details jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.promo_videos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  track_id uuid,
  title text,
  video_url text,
  thumbnail_url text,
  status text DEFAULT 'pending',
  is_public boolean DEFAULT false,
  views_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.gallery_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gallery_item_id uuid,
  user_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(gallery_item_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.permission_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE,
  description text,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.moderator_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  category_id uuid,
  can_edit boolean DEFAULT false,
  can_delete boolean DEFAULT false,
  can_ban boolean DEFAULT false,
  granted_by uuid,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.moderator_presets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  permissions jsonb DEFAULT '[]'::jsonb,
  created_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- MISSING RPC FUNCTIONS (not yet in DB)
-- ═══════════════════════════════════════════════════════════════════

-- pin_comment
CREATE OR REPLACE FUNCTION public.pin_comment(p_comment_id uuid, p_pinned boolean DEFAULT true)
RETURNS void AS $$
BEGIN
  UPDATE public.track_comments SET is_pinned = p_pinned WHERE id = p_comment_id;
END;
$$ LANGUAGE plpgsql;

-- Ensure is_pinned column exists
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='track_comments' AND column_name='is_pinned') THEN
    ALTER TABLE public.track_comments ADD COLUMN is_pinned boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='track_comments' AND column_name='is_hidden') THEN
    ALTER TABLE public.track_comments ADD COLUMN is_hidden boolean DEFAULT false;
  END IF;
END $$;

-- hide_track_comment
CREATE OR REPLACE FUNCTION public.hide_track_comment(p_comment_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.track_comments SET is_hidden = true WHERE id = p_comment_id;
END;
$$ LANGUAGE plpgsql;

-- get_user_emails (admin)
CREATE OR REPLACE FUNCTION public.get_user_emails(p_user_ids uuid[] DEFAULT NULL)
RETURNS TABLE(user_id uuid, email text) AS $$
BEGIN
  IF p_user_ids IS NULL THEN
    RETURN QUERY SELECT u.id, u.email FROM auth.users u;
  ELSE
    RETURN QUERY SELECT u.id, u.email FROM auth.users u WHERE u.id = ANY(p_user_ids);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- find_user_by_short_id
CREATE OR REPLACE FUNCTION public.find_user_by_short_id(p_short_id text)
RETURNS TABLE(user_id uuid, username text, display_name text, avatar_url text) AS $$
BEGIN
  RETURN QUERY
    SELECT p.user_id, p.username, p.display_name, p.avatar_url
    FROM public.profiles p
    WHERE p.short_id = p_short_id
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- create_admin_conversation
CREATE OR REPLACE FUNCTION public.create_admin_conversation(p_user_id uuid, p_admin_id uuid)
RETURNS uuid AS $$
DECLARE
  conv_id uuid;
BEGIN
  INSERT INTO public.conversations (type) VALUES ('admin') RETURNING id INTO conv_id;
  INSERT INTO public.conversation_participants (conversation_id, user_id) VALUES (conv_id, p_user_id);
  INSERT INTO public.conversation_participants (conversation_id, user_id) VALUES (conv_id, p_admin_id);
  RETURN conv_id;
END;
$$ LANGUAGE plpgsql;

-- close_admin_conversation
CREATE OR REPLACE FUNCTION public.close_admin_conversation(p_conversation_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.conversations SET type = 'closed', updated_at = now() WHERE id = p_conversation_id;
END;
$$ LANGUAGE plpgsql;

-- cleanup_old_logs
CREATE OR REPLACE FUNCTION public.cleanup_old_logs(p_days integer DEFAULT 30)
RETURNS integer AS $$
DECLARE
  deleted integer := 0;
  cnt integer;
BEGIN
  DELETE FROM public.error_logs WHERE created_at < now() - (p_days || ' days')::interval;
  GET DIAGNOSTICS cnt = ROW_COUNT; deleted := deleted + cnt;
  DELETE FROM public.generation_logs WHERE created_at < now() - (p_days || ' days')::interval AND status IN ('completed', 'failed');
  GET DIAGNOSTICS cnt = ROW_COUNT; deleted := deleted + cnt;
  DELETE FROM public.performance_alerts WHERE created_at < now() - (p_days || ' days')::interval AND resolved = true;
  GET DIAGNOSTICS cnt = ROW_COUNT; deleted := deleted + cnt;
  RETURN deleted;
END;
$$ LANGUAGE plpgsql;

-- accept_role_invitation
CREATE OR REPLACE FUNCTION public.accept_role_invitation(p_invitation_id uuid, p_user_id uuid)
RETURNS boolean AS $$
DECLARE
  inv record;
BEGIN
  SELECT * INTO inv FROM public.role_invitations
  WHERE id = p_invitation_id AND user_id = p_user_id AND status = 'pending' AND (expires_at IS NULL OR expires_at > now());
  IF NOT FOUND THEN RETURN false; END IF;

  UPDATE public.role_invitations SET status = 'accepted' WHERE id = p_invitation_id;

  INSERT INTO public.user_roles (user_id, role) VALUES (p_user_id, inv.role)
  ON CONFLICT DO NOTHING;

  UPDATE public.profiles SET role = inv.role WHERE user_id = p_user_id AND role = 'user';

  RETURN true;
END;
$$ LANGUAGE plpgsql;

-- purchase_track_boost
CREATE OR REPLACE FUNCTION public.purchase_track_boost(
  p_track_id uuid,
  p_user_id uuid,
  p_duration_hours integer DEFAULT 24,
  p_cost integer DEFAULT 50
)
RETURNS boolean AS $$
DECLARE
  current_balance integer;
BEGIN
  SELECT balance INTO current_balance FROM public.profiles WHERE user_id = p_user_id;
  IF current_balance IS NULL OR current_balance < p_cost THEN RETURN false; END IF;

  UPDATE public.profiles SET balance = balance - p_cost WHERE user_id = p_user_id;
  UPDATE public.tracks
  SET is_boosted = true, boost_expires_at = now() + (p_duration_hours || ' hours')::interval
  WHERE id = p_track_id AND user_id = p_user_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description, reference_type, reference_id)
  VALUES (p_user_id, -p_cost, 'boost', 'Boost трека', 'track', p_track_id);

  RETURN true;
END;
$$ LANGUAGE plpgsql;

-- update_last_seen
CREATE OR REPLACE FUNCTION public.update_last_seen(p_user_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.profiles SET last_seen_at = now() WHERE user_id = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- create_conversation_with_user
CREATE OR REPLACE FUNCTION public.create_conversation_with_user(p_user_id uuid, p_other_user_id uuid)
RETURNS uuid AS $$
DECLARE
  existing_conv_id uuid;
  new_conv_id uuid;
BEGIN
  SELECT cp1.conversation_id INTO existing_conv_id
  FROM public.conversation_participants cp1
  INNER JOIN public.conversation_participants cp2 ON cp1.conversation_id = cp2.conversation_id
  INNER JOIN public.conversations c ON c.id = cp1.conversation_id
  WHERE cp1.user_id = p_user_id AND cp2.user_id = p_other_user_id AND c.type = 'direct'
  LIMIT 1;

  IF existing_conv_id IS NOT NULL THEN RETURN existing_conv_id; END IF;

  INSERT INTO public.conversations (type) VALUES ('direct') RETURNING id INTO new_conv_id;
  INSERT INTO public.conversation_participants (conversation_id, user_id) VALUES (new_conv_id, p_user_id);
  INSERT INTO public.conversation_participants (conversation_id, user_id) VALUES (new_conv_id, p_other_user_id);
  RETURN new_conv_id;
END;
$$ LANGUAGE plpgsql;

-- generate_share_token
CREATE OR REPLACE FUNCTION public.generate_share_token(p_track_id uuid, p_user_id uuid)
RETURNS text AS $$
DECLARE
  token text;
BEGIN
  token := encode(gen_random_bytes(16), 'hex');
  UPDATE public.tracks SET share_token = token WHERE id = p_track_id AND user_id = p_user_id;
  RETURN token;
END;
$$ LANGUAGE plpgsql;

-- Ensure share_token column
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='share_token') THEN
    ALTER TABLE public.tracks ADD COLUMN share_token text;
  END IF;
END $$;

-- get_track_by_share_token
CREATE OR REPLACE FUNCTION public.get_track_by_share_token(p_token text)
RETURNS SETOF public.tracks AS $$
BEGIN
  RETURN QUERY SELECT * FROM public.tracks WHERE share_token = p_token LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- revoke_share_token
CREATE OR REPLACE FUNCTION public.revoke_share_token(p_track_id uuid, p_user_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.tracks SET share_token = NULL WHERE id = p_track_id AND user_id = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- get_track_prompt_info
CREATE OR REPLACE FUNCTION public.get_track_prompt_info(p_track_id uuid)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'has_prompt', (t.prompt_text IS NOT NULL AND t.prompt_text != ''),
    'is_public', t.is_public,
    'user_id', t.user_id
  ) INTO result
  FROM public.tracks t WHERE t.id = p_track_id;
  RETURN COALESCE(result, '{}'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- get_track_prompt_if_accessible
CREATE OR REPLACE FUNCTION public.get_track_prompt_if_accessible(p_track_id uuid, p_user_id uuid)
RETURNS text AS $$
DECLARE
  track_record record;
BEGIN
  SELECT prompt_text, user_id, is_public INTO track_record FROM public.tracks WHERE id = p_track_id;
  IF track_record.user_id = p_user_id OR track_record.is_public THEN
    RETURN track_record.prompt_text;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- get_or_create_referral_code
CREATE OR REPLACE FUNCTION public.get_or_create_referral_code(p_user_id uuid)
RETURNS text AS $$
DECLARE
  existing_code text;
  new_code text;
BEGIN
  SELECT code INTO existing_code FROM public.referral_codes WHERE user_id = p_user_id LIMIT 1;
  IF existing_code IS NOT NULL THEN RETURN existing_code; END IF;

  SELECT p.referral_code INTO existing_code FROM public.profiles p WHERE p.user_id = p_user_id;
  IF existing_code IS NOT NULL AND existing_code != '' THEN RETURN existing_code; END IF;

  new_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
  INSERT INTO public.referral_codes (user_id, code) VALUES (p_user_id, new_code) ON CONFLICT DO NOTHING;
  UPDATE public.profiles SET referral_code = new_code WHERE user_id = p_user_id AND (referral_code IS NULL OR referral_code = '');
  RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- block_user
CREATE OR REPLACE FUNCTION public.block_user(
  p_user_id uuid,
  p_reason text DEFAULT '',
  p_blocked_by uuid DEFAULT NULL,
  p_duration text DEFAULT NULL
)
RETURNS void AS $$
BEGIN
  INSERT INTO public.user_blocks (user_id, blocked_by, reason, expires_at)
  VALUES (p_user_id, p_blocked_by, p_reason,
    CASE WHEN p_duration IS NOT NULL THEN now() + p_duration::interval ELSE NULL END);

  UPDATE public.profiles
  SET is_blocked = true, blocked_at = now(), blocked_reason = p_reason, blocked_by = p_blocked_by
  WHERE user_id = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- unblock_user
CREATE OR REPLACE FUNCTION public.unblock_user(p_user_id uuid)
RETURNS void AS $$
BEGIN
  DELETE FROM public.user_blocks WHERE user_id = p_user_id;
  UPDATE public.profiles
  SET is_blocked = false, blocked_at = NULL, blocked_reason = NULL, blocked_by = NULL
  WHERE user_id = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- get_ad_for_slot
CREATE OR REPLACE FUNCTION public.get_ad_for_slot(p_slot_type text, p_user_id uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'campaign_id', c.id,
    'creative', jsonb_build_object(
      'id', cr.id, 'type', cr.type, 'title', cr.title,
      'description', cr.description, 'media_url', cr.media_url,
      'click_url', cr.click_url, 'cta_text', cr.cta_text
    )
  ) INTO result
  FROM public.ad_campaigns c
  JOIN public.ad_creatives cr ON cr.campaign_id = c.id AND cr.is_active = true
  JOIN public.ad_campaign_slots cs ON cs.campaign_id = c.id
  JOIN public.ad_slots s ON s.id = cs.slot_id AND s.slot_type = p_slot_type
  WHERE c.status = 'active' AND c.is_active = true
  ORDER BY cs.priority DESC, random()
  LIMIT 1;

  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- record_ad_impression
CREATE OR REPLACE FUNCTION public.record_ad_impression(p_campaign_id uuid, p_creative_id uuid, p_slot_id uuid DEFAULT NULL, p_user_id uuid DEFAULT NULL)
RETURNS void AS $$
BEGIN
  INSERT INTO public.ad_impressions (campaign_id, creative_id, slot_id, user_id)
  VALUES (p_campaign_id, p_creative_id, p_slot_id, p_user_id);
END;
$$ LANGUAGE plpgsql;

-- record_ad_click
CREATE OR REPLACE FUNCTION public.record_ad_click(p_campaign_id uuid, p_creative_id uuid, p_slot_id uuid DEFAULT NULL, p_user_id uuid DEFAULT NULL)
RETURNS void AS $$
BEGIN
  INSERT INTO public.ad_impressions (campaign_id, creative_id, slot_id, user_id, is_click)
  VALUES (p_campaign_id, p_creative_id, p_slot_id, p_user_id, true);
END;
$$ LANGUAGE plpgsql;

-- purchase_ad_free
CREATE OR REPLACE FUNCTION public.purchase_ad_free(p_user_id uuid, p_days integer DEFAULT 30, p_cost integer DEFAULT 99)
RETURNS boolean AS $$
DECLARE
  current_balance integer;
BEGIN
  SELECT balance INTO current_balance FROM public.profiles WHERE user_id = p_user_id;
  IF current_balance IS NULL OR current_balance < p_cost THEN RETURN false; END IF;

  UPDATE public.profiles
  SET balance = balance - p_cost,
      ad_free_until = GREATEST(COALESCE(ad_free_until, now()), now()) + (p_days || ' days')::interval
  WHERE user_id = p_user_id;

  INSERT INTO public.balance_transactions (user_id, amount, type, description)
  VALUES (p_user_id, -p_cost, 'ad_free', 'Покупка отключения рекламы');

  RETURN true;
END;
$$ LANGUAGE plpgsql;

-- has_purchased_item
CREATE OR REPLACE FUNCTION public.has_purchased_item(p_item_id uuid, p_user_id uuid)
RETURNS boolean AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM public.item_purchases WHERE item_id = p_item_id AND buyer_id = p_user_id AND status = 'completed');
END;
$$ LANGUAGE plpgsql;

-- has_purchased_prompt
CREATE OR REPLACE FUNCTION public.has_purchased_prompt(p_prompt_id uuid, p_user_id uuid)
RETURNS boolean AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM public.prompt_purchases WHERE prompt_id = p_prompt_id AND buyer_id = p_user_id AND status = 'completed');
END;
$$ LANGUAGE plpgsql;

-- increment_prompt_downloads
CREATE OR REPLACE FUNCTION public.increment_prompt_downloads(p_prompt_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;
END;
$$ LANGUAGE plpgsql;

-- process_beat_purchase
CREATE OR REPLACE FUNCTION public.process_beat_purchase(
  p_beat_id uuid, p_buyer_id uuid, p_license_type text DEFAULT 'basic'
)
RETURNS uuid AS $$
DECLARE
  beat record;
  purchase_id uuid;
BEGIN
  SELECT * INTO beat FROM public.store_beats WHERE id = p_beat_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Beat not found or inactive'; END IF;

  UPDATE public.profiles SET balance = balance - beat.price WHERE user_id = p_buyer_id AND balance >= beat.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.beat_purchases (buyer_id, beat_id, seller_id, price, license_type, status)
  VALUES (p_buyer_id, p_beat_id, beat.seller_id, beat.price, p_license_type, 'completed')
  RETURNING id INTO purchase_id;

  UPDATE public.store_beats SET sales_count = sales_count + 1 WHERE id = p_beat_id;

  INSERT INTO public.seller_earnings (seller_id, amount, source_type, source_id, platform_fee, net_amount, status)
  VALUES (beat.seller_id, beat.price, 'beat_sale', purchase_id, beat.price * 0.1, beat.price * 0.9, 'pending');

  RETURN purchase_id;
END;
$$ LANGUAGE plpgsql;

-- process_prompt_purchase
CREATE OR REPLACE FUNCTION public.process_prompt_purchase(p_prompt_id uuid, p_buyer_id uuid)
RETURNS uuid AS $$
DECLARE
  prompt record;
  purchase_id uuid;
BEGIN
  SELECT * INTO prompt FROM public.user_prompts WHERE id = p_prompt_id AND is_public = true AND price > 0;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prompt not found'; END IF;

  UPDATE public.profiles SET balance = balance - prompt.price WHERE user_id = p_buyer_id AND balance >= prompt.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.prompt_purchases (buyer_id, prompt_id, seller_id, price, status)
  VALUES (p_buyer_id, p_prompt_id, prompt.user_id, prompt.price, 'completed')
  RETURNING id INTO purchase_id;

  UPDATE public.user_prompts SET downloads_count = downloads_count + 1 WHERE id = p_prompt_id;
  RETURN purchase_id;
END;
$$ LANGUAGE plpgsql;

-- process_store_item_purchase
CREATE OR REPLACE FUNCTION public.process_store_item_purchase(p_item_id uuid, p_buyer_id uuid)
RETURNS uuid AS $$
DECLARE
  item record;
  purchase_id uuid;
BEGIN
  SELECT * INTO item FROM public.store_items WHERE id = p_item_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item not found'; END IF;

  UPDATE public.profiles SET balance = balance - item.price WHERE user_id = p_buyer_id AND balance >= item.price;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient balance'; END IF;

  INSERT INTO public.item_purchases (item_id, buyer_id, seller_id, price, status)
  VALUES (p_item_id, p_buyer_id, item.user_id, item.price, 'completed')
  RETURNING id INTO purchase_id;

  UPDATE public.store_items SET sales_count = sales_count + 1 WHERE id = p_item_id;
  RETURN purchase_id;
END;
$$ LANGUAGE plpgsql;

-- send_track_to_voting
CREATE OR REPLACE FUNCTION public.send_track_to_voting(p_track_id uuid, p_user_id uuid, p_voting_type text DEFAULT 'community')
RETURNS boolean AS $$
BEGIN
  UPDATE public.tracks
  SET moderation_status = 'voting',
      voting_started_at = now(),
      voting_ends_at = now() + interval '7 days',
      voting_type = p_voting_type,
      voting_likes_count = 0,
      voting_dislikes_count = 0
  WHERE id = p_track_id AND user_id = p_user_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- resolve_track_voting
CREATE OR REPLACE FUNCTION public.resolve_track_voting(p_track_id uuid, p_result text DEFAULT 'approved')
RETURNS void AS $$
BEGIN
  UPDATE public.tracks
  SET moderation_status = CASE WHEN p_result = 'approved' THEN 'approved' ELSE 'rejected' END,
      voting_result = p_result
  WHERE id = p_track_id;
END;
$$ LANGUAGE plpgsql;

-- create_voting_forum_topic
CREATE OR REPLACE FUNCTION public.create_voting_forum_topic(p_track_id uuid, p_title text, p_content text DEFAULT '')
RETURNS uuid AS $$
DECLARE
  topic_id uuid;
  track_user_id uuid;
BEGIN
  SELECT user_id INTO track_user_id FROM public.tracks WHERE id = p_track_id;

  INSERT INTO public.forum_topics (user_id, title, content, track_id, tags)
  VALUES (track_user_id, p_title, p_content, p_track_id, ARRAY['voting'])
  RETURNING id INTO topic_id;

  RETURN topic_id;
END;
$$ LANGUAGE plpgsql;

-- close_voting_topic_on_rejection
CREATE OR REPLACE FUNCTION public.close_voting_topic_on_rejection(p_track_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.forum_topics SET is_locked = true WHERE track_id = p_track_id;
END;
$$ LANGUAGE plpgsql;

-- delete_forum_topic_cascade
CREATE OR REPLACE FUNCTION public.delete_forum_topic_cascade(p_topic_id uuid)
RETURNS void AS $$
BEGIN
  DELETE FROM public.forum_posts WHERE topic_id = p_topic_id;
  DELETE FROM public.forum_topics WHERE id = p_topic_id;
END;
$$ LANGUAGE plpgsql;

-- forum_search
CREATE OR REPLACE FUNCTION public.forum_search(p_query text, p_limit integer DEFAULT 20)
RETURNS TABLE(id uuid, title text, content text, type text, created_at timestamptz) AS $$
BEGIN
  RETURN QUERY (
    SELECT t.id, t.title, t.content, 'topic'::text, t.created_at
    FROM public.forum_topics t
    WHERE t.title ILIKE '%' || p_query || '%' OR t.content ILIKE '%' || p_query || '%'
    UNION ALL
    SELECT p.id, ''::text, p.content, 'post'::text, p.created_at
    FROM public.forum_posts p
    WHERE p.content ILIKE '%' || p_query || '%'
  ) ORDER BY created_at DESC LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- forum_increment_topic_views
CREATE OR REPLACE FUNCTION public.forum_increment_topic_views(p_topic_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.forum_topics SET views_count = views_count + 1 WHERE id = p_topic_id;
END;
$$ LANGUAGE plpgsql;

-- forum_mark_read
CREATE OR REPLACE FUNCTION public.forum_mark_read(p_user_id uuid, p_topic_id uuid)
RETURNS void AS $$
BEGIN
  INSERT INTO public.forum_user_reads (user_id, topic_id, last_read_at)
  VALUES (p_user_id, p_topic_id, now())
  ON CONFLICT (user_id, topic_id) DO UPDATE SET last_read_at = now();
END;
$$ LANGUAGE plpgsql;

-- forum_mark_solution
CREATE OR REPLACE FUNCTION public.forum_mark_solution(p_post_id uuid, p_topic_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.forum_posts SET is_solution = true WHERE id = p_post_id;
  UPDATE public.forum_topics SET is_solved = true WHERE id = p_topic_id;
END;
$$ LANGUAGE plpgsql;

-- Ensure is_solution / is_solved columns
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='forum_posts' AND column_name='is_solution') THEN
    ALTER TABLE public.forum_posts ADD COLUMN is_solution boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='forum_topics' AND column_name='is_solved') THEN
    ALTER TABLE public.forum_topics ADD COLUMN is_solved boolean DEFAULT false;
  END IF;
END $$;

-- forum_get_leaderboard
CREATE OR REPLACE FUNCTION public.forum_get_leaderboard(p_limit integer DEFAULT 10)
RETURNS TABLE(user_id uuid, username text, avatar_url text, reputation integer, posts_count integer) AS $$
BEGIN
  RETURN QUERY
    SELECT fs.user_id, p.username, p.avatar_url, fs.reputation, fs.posts_count
    FROM public.forum_user_stats fs
    LEFT JOIN public.profiles p ON p.user_id = fs.user_id
    ORDER BY fs.reputation DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- forum_get_user_profile
CREATE OR REPLACE FUNCTION public.forum_get_user_profile(p_user_id uuid)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'user_id', fs.user_id,
    'topics_count', fs.topics_count,
    'posts_count', fs.posts_count,
    'likes_received', fs.likes_received,
    'reputation', fs.reputation,
    'trust_level', fs.trust_level,
    'solutions_count', fs.solutions_count
  ) INTO result
  FROM public.forum_user_stats fs
  WHERE fs.user_id = p_user_id;

  RETURN COALESCE(result, jsonb_build_object(
    'user_id', p_user_id, 'topics_count', 0, 'posts_count', 0,
    'likes_received', 0, 'reputation', 0, 'trust_level', 0, 'solutions_count', 0
  ));
END;
$$ LANGUAGE plpgsql;

-- forum_moderate_promo
CREATE OR REPLACE FUNCTION public.forum_moderate_promo(p_promo_id uuid, p_action text)
RETURNS void AS $$
BEGIN
  IF p_action = 'approve' THEN
    UPDATE public.forum_promo_slots SET is_active = true WHERE id = p_promo_id;
  ELSIF p_action = 'reject' THEN
    DELETE FROM public.forum_promo_slots WHERE id = p_promo_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- hide_contest_comment
CREATE OR REPLACE FUNCTION public.hide_contest_comment(p_comment_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.contest_entry_comments SET is_hidden = true WHERE id = p_comment_id;
END;
$$ LANGUAGE plpgsql;

-- unhide_contest_comment
CREATE OR REPLACE FUNCTION public.unhide_contest_comment(p_comment_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.contest_entry_comments SET is_hidden = false WHERE id = p_comment_id;
END;
$$ LANGUAGE plpgsql;

-- Ensure is_hidden column on contest_entry_comments
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='contest_entry_comments' AND column_name='is_hidden') THEN
    ALTER TABLE public.contest_entry_comments ADD COLUMN is_hidden boolean DEFAULT false;
  END IF;
END $$;

-- award_contest_prize: removed conflicting stub.
-- The full implementation lives in 001-schema.sql with signature (_winner_id uuid, _contest_id uuid)
-- and handles prize lookup, duplicate check, notifications, etc.

-- finalize_contest_winners
CREATE OR REPLACE FUNCTION public.finalize_contest_winners(p_contest_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.contests SET status = 'completed', updated_at = now() WHERE id = p_contest_id;
END;
$$ LANGUAGE plpgsql;

-- withdraw_contest_entry
CREATE OR REPLACE FUNCTION public.withdraw_contest_entry(p_entry_id uuid, p_user_id uuid)
RETURNS boolean AS $$
BEGIN
  DELETE FROM public.contest_entries WHERE id = p_entry_id AND user_id = p_user_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql;


SELECT 'AUDIT: ALL MISSING TABLES, VIEWS, AND RPC FUNCTIONS CREATED' as status;
