DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.addon_services
    WHERE name = 'short_video'
  ) THEN
    UPDATE public.addon_services
    SET
      name_ru = 'Музыкальное видео',
      description = 'Suno Music Video для готового трека в формате MP4',
      price_rub = 12,
      icon = 'video',
      is_active = true,
      updated_at = now()
    WHERE name = 'short_video';
  ELSE
    INSERT INTO public.addon_services (
      name,
      name_ru,
      description,
      price_rub,
      icon,
      is_active,
      sort_order
    ) VALUES (
      'short_video',
      'Музыкальное видео',
      'Suno Music Video для готового трека в формате MP4',
      12,
      'video',
      true,
      4
    );
  END IF;
END $$;
