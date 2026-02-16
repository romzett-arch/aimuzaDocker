-- =====================================================
-- 010-json-schema-sync.sql
-- Синхронизация схемы БД с JSON-бэкапом (full-backup-2026-02-13.json)
-- Добавляет недостающие колонки. Безопасно: IF NOT EXISTS.
-- =====================================================

-- ── addon_services ──────────────────────────────────
ALTER TABLE public.addon_services ADD COLUMN IF NOT EXISTS price_aipci numeric DEFAULT 0;
ALTER TABLE public.addon_services ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- ── lyrics_items ────────────────────────────────────
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS genre_id uuid;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS is_exclusive boolean DEFAULT false;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS is_for_sale boolean DEFAULT false;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS language text;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS license_type text;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS sales_count integer DEFAULT 0;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS track_id uuid;
ALTER TABLE public.lyrics_items ADD COLUMN IF NOT EXISTS views_count integer DEFAULT 0;

-- ── notifications ───────────────────────────────────
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS actor_id uuid;
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS link text;
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS metadata jsonb DEFAULT '{}';
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS target_id uuid;
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS target_type text;

-- ── payments ────────────────────────────────────────
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS external_id text;
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS payment_system text;

-- ── playlists ───────────────────────────────────────
ALTER TABLE public.playlists ADD COLUMN IF NOT EXISTS likes_count integer DEFAULT 0;
ALTER TABLE public.playlists ADD COLUMN IF NOT EXISTS plays_count integer DEFAULT 0;

-- ── profiles ────────────────────────────────────────
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS ad_free_purchased_at timestamptz;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS contest_participations integer DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS contest_wins jsonb DEFAULT '[]';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS contest_wins_count integer DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS email_last_changed_at timestamptz;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS total_prize_won numeric DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS verification_type text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS verified_at timestamptz;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS verified_by uuid;

-- ── settings ────────────────────────────────────────
ALTER TABLE public.settings ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
ALTER TABLE public.settings ADD COLUMN IF NOT EXISTS description text;

-- ── store_items ─────────────────────────────────────
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS genre_id uuid;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS is_exclusive boolean DEFAULT false;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS item_type text;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS license_terms text;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS license_type text;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS preview_url text;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS seller_id uuid;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS source_id uuid;
ALTER TABLE public.store_items ADD COLUMN IF NOT EXISTS views_count integer DEFAULT 0;

-- ── subscription_plans ──────────────────────────────
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS badge_emoji text;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS commercial_license boolean DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS generation_credits integer DEFAULT 0;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS no_watermark boolean DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS priority_generation boolean DEFAULT false;
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS service_quotas jsonb DEFAULT '{}';
ALTER TABLE public.subscription_plans ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- ── tracks ──────────────────────────────────────────
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS audio_reference_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS blockchain_hash text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_approved_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_approved_by uuid;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_platforms jsonb;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_rejection_reason text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_requested_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_reviewed_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_reviewed_by uuid;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS distribution_submitted_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS gold_pack_url text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS has_interpolations boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS interpolations_licensed boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS isrc_code text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS lufs_normalized boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS lyrics_author text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS master_uploaded_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS metadata_cleaned boolean DEFAULT false;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS music_author text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_completed_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_progress integer DEFAULT 0;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_stage text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS processing_started_at timestamptz;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS suno_audio_id text;
ALTER TABLE public.tracks ADD COLUMN IF NOT EXISTS upscale_detected boolean DEFAULT false;
