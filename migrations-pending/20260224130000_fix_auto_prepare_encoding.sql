-- Fix name_ru encoding for auto_prepare (corrupted UTF-8 in DB)
UPDATE public.addon_services 
SET name_ru = 'AI Промт + теги' 
WHERE name = 'auto_prepare';
