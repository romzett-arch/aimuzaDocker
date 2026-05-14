
-- 1. Create the voting category
INSERT INTO public.forum_categories (id, name, name_ru, slug, description_ru, icon, color, sort_order, is_active, is_locked, min_trust_level)
VALUES (
  '667eca41-29ad-40bf-bf92-cceec00f5875',
  'Voting',
  'Голосование',
  'voting',
  'Треки на голосовании сообщества перед дистрибуцией',
  '🗳️',
  '#8b5cf6',
  50,
  true,
  true,
  0
)
ON CONFLICT (id) DO NOTHING;
