-- ═══════════════════════════════════════════════════════════════════
-- REALTIME: PG NOTIFY триггеры для WebSocket сервера
-- При INSERT/UPDATE/DELETE на отслеживаемых таблицах —
-- шлём pg_notify('table_changes', json) с данными строки
-- ═══════════════════════════════════════════════════════════════════

-- 1. Недостающие таблицы

CREATE TABLE IF NOT EXISTS public.ticket_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  message text NOT NULL,
  is_staff boolean DEFAULT false,
  attachment_url text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.contest_entry_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id uuid REFERENCES public.contest_entries(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  content text NOT NULL,
  parent_id uuid,
  likes_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.contest_winners (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id uuid REFERENCES public.contests(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  entry_id uuid REFERENCES public.contest_entries(id) ON DELETE SET NULL,
  place integer DEFAULT 1,
  prize_description text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.track_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid REFERENCES public.tracks(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  content text NOT NULL,
  parent_id uuid,
  likes_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.message_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid REFERENCES public.messages(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  emoji text NOT NULL,
  conversation_id uuid,
  created_at timestamptz DEFAULT now(),
  UNIQUE(message_id, user_id, emoji)
);


-- 2. Универсальная функция NOTIFY

CREATE OR REPLACE FUNCTION public.notify_table_change()
RETURNS TRIGGER AS $$
DECLARE
  payload jsonb;
  record_data jsonb;
  op text;
BEGIN
  op := TG_OP;

  IF op = 'DELETE' THEN
    record_data := to_jsonb(OLD);
  ELSE
    record_data := to_jsonb(NEW);
  END IF;

  -- Ограничиваем размер payload (PG NOTIFY max 8000 bytes)
  -- Отправляем только ключевые поля
  payload := jsonb_build_object(
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA,
    'type', op,
    'record', record_data,
    'old_record', CASE WHEN op = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END
  );

  -- Если payload слишком большой — отправляем только id
  IF length(payload::text) > 7500 THEN
    payload := jsonb_build_object(
      'table', TG_TABLE_NAME,
      'schema', TG_TABLE_SCHEMA,
      'type', op,
      'record', jsonb_build_object('id', CASE WHEN op = 'DELETE' THEN OLD.id ELSE NEW.id END),
      'old_record', NULL
    );
  END IF;

  PERFORM pg_notify('table_changes', payload::text);

  IF op = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 3. Создаём триггеры на всех 15+ таблицах

DO $$
DECLARE
  tbl text;
  tables text[] := ARRAY[
    'tracks',
    'track_addons',
    'notifications',
    'messages',
    'conversations',
    'conversation_participants',
    'message_reactions',
    'support_tickets',
    'ticket_messages',
    'forum_posts',
    'forum_topics',
    'contest_entries',
    'contest_entry_comments',
    'contest_winners',
    'track_comments',
    'radio_slots',
    'radio_bids',
    'radio_predictions'
  ];
BEGIN
  FOREACH tbl IN ARRAY tables LOOP
    -- Проверяем что таблица существует
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = tbl) THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_notify_%I ON public.%I', tbl, tbl);
      EXECUTE format('
        CREATE TRIGGER trg_notify_%I
          AFTER INSERT OR UPDATE OR DELETE ON public.%I
          FOR EACH ROW
          EXECUTE FUNCTION public.notify_table_change()
      ', tbl, tbl);
      RAISE NOTICE 'Trigger created for: %', tbl;
    ELSE
      RAISE WARNING 'Table % does not exist, skipping', tbl;
    END IF;
  END LOOP;
END $$;


SELECT 'REALTIME TRIGGERS READY' as status;
