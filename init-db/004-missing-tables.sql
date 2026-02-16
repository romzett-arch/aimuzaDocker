-- ═══════════════════════════════════════════════════════════════════
-- ВСЕ НЕДОСТАЮЩИЕ ТАБЛИЦЫ + КОЛОНКИ для фронтенда aimuza.ru
-- ═══════════════════════════════════════════════════════════════════

-- ── Расширение profiles ────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='onboarding_completed') THEN
    ALTER TABLE public.profiles ADD COLUMN onboarding_completed boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='ad_free_until') THEN
    ALTER TABLE public.profiles ADD COLUMN ad_free_until timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='is_blocked') THEN
    ALTER TABLE public.profiles ADD COLUMN is_blocked boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='blocked_at') THEN
    ALTER TABLE public.profiles ADD COLUMN blocked_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='blocked_reason') THEN
    ALTER TABLE public.profiles ADD COLUMN blocked_reason text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='blocked_by') THEN
    ALTER TABLE public.profiles ADD COLUMN blocked_by uuid;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='referral_code') THEN
    ALTER TABLE public.profiles ADD COLUMN referral_code text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='referred_by') THEN
    ALTER TABLE public.profiles ADD COLUMN referred_by uuid;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='cover_url') THEN
    ALTER TABLE public.profiles ADD COLUMN cover_url text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='social_links') THEN
    ALTER TABLE public.profiles ADD COLUMN social_links jsonb DEFAULT '{}'::jsonb;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles' AND column_name='notification_settings') THEN
    ALTER TABLE public.profiles ADD COLUMN notification_settings jsonb DEFAULT '{}'::jsonb;
  END IF;
END $$;

-- Обновляем суперадмина
UPDATE public.profiles SET onboarding_completed = true WHERE is_protected = true;


-- ── Расширение tracks ──────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='moderation_status') THEN
    ALTER TABLE public.tracks ADD COLUMN moderation_status text DEFAULT 'none';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='source_type') THEN
    ALTER TABLE public.tracks ADD COLUMN source_type text DEFAULT 'generated';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='distribution_status') THEN
    ALTER TABLE public.tracks ADD COLUMN distribution_status text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='voting_started_at') THEN
    ALTER TABLE public.tracks ADD COLUMN voting_started_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='voting_ends_at') THEN
    ALTER TABLE public.tracks ADD COLUMN voting_ends_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='voting_likes_count') THEN
    ALTER TABLE public.tracks ADD COLUMN voting_likes_count integer DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='voting_dislikes_count') THEN
    ALTER TABLE public.tracks ADD COLUMN voting_dislikes_count integer DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='voting_result') THEN
    ALTER TABLE public.tracks ADD COLUMN voting_result text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='voting_type') THEN
    ALTER TABLE public.tracks ADD COLUMN voting_type text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='prompt_text') THEN
    ALTER TABLE public.tracks ADD COLUMN prompt_text text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='tags') THEN
    ALTER TABLE public.tracks ADD COLUMN tags text[];
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='bpm') THEN
    ALTER TABLE public.tracks ADD COLUMN bpm integer;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='key_signature') THEN
    ALTER TABLE public.tracks ADD COLUMN key_signature text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='suno_id') THEN
    ALTER TABLE public.tracks ADD COLUMN suno_id text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='video_url') THEN
    ALTER TABLE public.tracks ADD COLUMN video_url text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='is_boosted') THEN
    ALTER TABLE public.tracks ADD COLUMN is_boosted boolean DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='boost_expires_at') THEN
    ALTER TABLE public.tracks ADD COLUMN boost_expires_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='downloads_count') THEN
    ALTER TABLE public.tracks ADD COLUMN downloads_count integer DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='tracks' AND column_name='shares_count') THEN
    ALTER TABLE public.tracks ADD COLUMN shares_count integer DEFAULT 0;
  END IF;
END $$;


-- ── admin_announcements ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_announcements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text,
  content text,
  type text DEFAULT 'info',
  is_published boolean DEFAULT false,
  publish_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ── role_invitations ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.role_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL,
  status text DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  invited_by uuid,
  message text,
  expires_at timestamptz DEFAULT (now() + interval '7 days'),
  responded_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.role_invitation_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id uuid REFERENCES public.role_invitations(id) ON DELETE CASCADE,
  category_id uuid REFERENCES public.permission_categories(id) ON DELETE CASCADE,
  UNIQUE(invitation_id, category_id)
);

-- ── permission_categories (if missing) ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.permission_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE,
  name text NOT NULL,
  name_ru text,
  slug text UNIQUE,
  description text,
  icon text,
  sort_order integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

-- ── moderator_presets (if missing) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.moderator_presets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  name_ru text,
  description text,
  permissions jsonb DEFAULT '[]'::jsonb,
  category_ids uuid[] DEFAULT ARRAY[]::uuid[],
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

-- ── moderator_permissions (if missing) ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.moderator_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  category_id uuid REFERENCES public.permission_categories(id) ON DELETE CASCADE,
  granted_by uuid,
  granted_at timestamptz DEFAULT now(),
  UNIQUE(user_id, category_id)
);

-- ── role_change_logs (if missing) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS public.role_change_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  changed_by uuid,
  action text NOT NULL CHECK (action IN (
    'invited', 'accepted', 'declined', 'revoked', 'expired', 'assigned',
    'blocked', 'unblocked', 'invitation_cancelled',
    'user_deleted', 'moderation_sent_to_voting', 'balance_changed', 'moderation_approved'
  )),
  old_role app_role,
  new_role app_role,
  reason text,
  metadata jsonb,
  created_at timestamptz DEFAULT now()
);

-- ── conversations & participants ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text DEFAULT 'direct',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.conversation_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES public.conversations(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  last_read_at timestamptz,
  created_at timestamptz DEFAULT now(),
  UNIQUE(conversation_id, user_id)
);

-- ── user_follows ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_follows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  following_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(follower_id, following_id)
);

-- ── contests ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.contests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  genre_id uuid,
  status text DEFAULT 'draft',
  start_date timestamptz,
  end_date timestamptz,
  prize_description text,
  prize_amount integer DEFAULT 0,
  max_entries integer,
  rules text,
  cover_url text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.contest_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id uuid REFERENCES public.contests(id) ON DELETE CASCADE,
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  score numeric DEFAULT 0,
  status text DEFAULT 'submitted',
  created_at timestamptz DEFAULT now()
);

-- ── forum ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.forum_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE,
  description text,
  icon text,
  sort_order integer DEFAULT 0,
  is_hidden boolean DEFAULT false,
  topics_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_topics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  content text,
  is_pinned boolean DEFAULT false,
  is_locked boolean DEFAULT false,
  is_hidden boolean DEFAULT false,
  posts_count integer DEFAULT 0,
  views_count integer DEFAULT 0,
  last_post_at timestamptz,
  last_post_user_id uuid,
  bumped_at timestamptz DEFAULT now(),
  track_id uuid,
  tags text[],
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  content text NOT NULL,
  is_hidden boolean DEFAULT false,
  likes_count integer DEFAULT 0,
  parent_id uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ── addon_services ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.addon_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  name_ru text,
  description text,
  description_ru text,
  price_rub integer DEFAULT 0,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  category text DEFAULT 'audio',
  icon text,
  created_at timestamptz DEFAULT now()
);

-- ── track_addons ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.track_addons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  addon_service_id uuid REFERENCES public.addon_services(id),
  status text DEFAULT 'pending',
  result_url text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ── generation_logs ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.generation_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id uuid,
  model text,
  prompt text,
  status text DEFAULT 'pending',
  cost_rub integer DEFAULT 0,
  duration_ms integer,
  error_message text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

-- ── subscription_plans ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.subscription_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  name_ru text,
  description text,
  price_monthly integer DEFAULT 0,
  price_yearly integer DEFAULT 0,
  features jsonb DEFAULT '[]'::jsonb,
  daily_generations integer DEFAULT 5,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

-- Дефолтные планы
INSERT INTO public.subscription_plans (name, name_ru, price_monthly, daily_generations, sort_order, is_active) VALUES
  ('free', 'Бесплатный', 0, 5, 0, true),
  ('basic', 'Базовый', 299, 20, 1, true),
  ('premium', 'Премиум', 599, 50, 2, true),
  ('pro', 'PRO', 999, 100, 3, true)
ON CONFLICT DO NOTHING;


-- ── store_beats ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.store_beats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  title text,
  description text,
  price integer DEFAULT 0,
  license_type text DEFAULT 'basic',
  is_active boolean DEFAULT true,
  sales_count integer DEFAULT 0,
  tags text[],
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ── beat_purchases ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.beat_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beat_id uuid REFERENCES public.store_beats(id) ON DELETE SET NULL,
  buyer_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  seller_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  price integer DEFAULT 0,
  status text DEFAULT 'pending',
  license_type text DEFAULT 'basic',
  created_at timestamptz DEFAULT now()
);

-- ── seller_earnings ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.seller_earnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  source_type text,
  source_id uuid,
  amount numeric DEFAULT 0,
  platform_fee numeric DEFAULT 0,
  net_amount numeric DEFAULT 0,
  status text DEFAULT 'pending',
  created_at timestamptz DEFAULT now()
);

-- ── user_prompts ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  prompt_text text NOT NULL,
  genre text,
  tags text[],
  price integer DEFAULT 0,
  is_public boolean DEFAULT false,
  downloads_count integer DEFAULT 0,
  rating numeric DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ── payout_requests ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.payout_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  amount numeric NOT NULL,
  payment_method text,
  payment_details text,
  status text DEFAULT 'pending',
  processed_at timestamptz,
  processed_by uuid,
  notes text,
  created_at timestamptz DEFAULT now()
);

-- ── support_tickets ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.support_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  subject text NOT NULL,
  message text NOT NULL,
  status text DEFAULT 'open',
  priority text DEFAULT 'normal',
  category text,
  assigned_to uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.support_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  message text NOT NULL,
  is_staff boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

-- ── user_blocks ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reason text,
  expires_at timestamptz,
  created_at timestamptz DEFAULT now()
);

-- ── referrals ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  referred_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  bonus_amount integer DEFAULT 0,
  status text DEFAULT 'pending',
  created_at timestamptz DEFAULT now()
);

-- ── email_verifications ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.email_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  code text NOT NULL,
  username text,
  verified boolean DEFAULT false,
  expires_at timestamptz DEFAULT (now() + interval '15 minutes'),
  created_at timestamptz DEFAULT now()
);

-- ── track_reports ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.track_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  reporter_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reason text NOT NULL,
  status text DEFAULT 'pending',
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz DEFAULT now()
);

-- ── distribution_requests ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.distribution_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  platforms jsonb DEFAULT '[]'::jsonb,
  status text DEFAULT 'pending',
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ── personas (AI персонажи) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.personas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  avatar_url text,
  voice_style text,
  settings jsonb DEFAULT '{}'::jsonb,
  is_public boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);


-- ═══════════════════════════════════════════════════════════════════
-- RPC ФУНКЦИИ
-- ═══════════════════════════════════════════════════════════════════

-- is_user_blocked
CREATE OR REPLACE FUNCTION public.is_user_blocked(p_user_id uuid DEFAULT NULL)
RETURNS boolean AS $$
BEGIN
  IF p_user_id IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.user_blocks 
    WHERE user_id = p_user_id 
    AND (expires_at IS NULL OR expires_at > now())
  );
END;
$$ LANGUAGE plpgsql;

-- get_user_block_info
CREATE OR REPLACE FUNCTION public.get_user_block_info(p_user_id uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  result jsonb;
BEGIN
  IF p_user_id IS NULL THEN RETURN '{"is_blocked": false}'::jsonb; END IF;
  
  SELECT jsonb_build_object(
    'is_blocked', true,
    'reason', b.reason,
    'expires_at', b.expires_at,
    'created_at', b.created_at
  ) INTO result
  FROM public.user_blocks b
  WHERE b.user_id = p_user_id
  AND (b.expires_at IS NULL OR b.expires_at > now())
  ORDER BY b.created_at DESC
  LIMIT 1;
  
  RETURN COALESCE(result, '{"is_blocked": false}'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- get_boosted_tracks
CREATE OR REPLACE FUNCTION public.get_boosted_tracks(p_limit integer DEFAULT 5)
RETURNS SETOF public.tracks AS $$
BEGIN
  RETURN QUERY
    SELECT * FROM public.tracks
    WHERE is_boosted = true
    AND (boost_expires_at IS NULL OR boost_expires_at > now())
    AND is_public = true AND status = 'completed'
    ORDER BY boost_expires_at DESC NULLS LAST
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- get_feed_tracks_with_profiles
CREATE OR REPLACE FUNCTION public.get_feed_tracks_with_profiles(
  p_user_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid, title text, description text, audio_url text, cover_url text,
  duration integer, user_id uuid, genre_id uuid, likes_count integer,
  plays_count integer, status text, created_at timestamptz,
  username text, avatar_url text, display_name text
) AS $$
BEGIN
  RETURN QUERY
    SELECT t.id, t.title, t.description, t.audio_url, t.cover_url,
           t.duration, t.user_id, t.genre_id, t.likes_count,
           t.plays_count, t.status, t.created_at,
           p.username, p.avatar_url, p.display_name
    FROM public.tracks t
    LEFT JOIN public.profiles p ON p.user_id = t.user_id
    WHERE t.is_public = true AND t.status = 'completed'
    ORDER BY t.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;


-- ── role_change_logs ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.role_change_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  changed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  action text,
  reason text,
  metadata jsonb,
  old_role text,
  new_role text,
  created_at timestamptz DEFAULT now()
);

SELECT 'ALL MISSING TABLES AND FUNCTIONS CREATED' as status;
