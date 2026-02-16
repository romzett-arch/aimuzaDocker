-- Добавить super_admin в enum и назначить romzett@mail.ru
-- Защитить роль на уровне триггера

-- 1. Добавить super_admin в enum app_role
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'super_admin';
