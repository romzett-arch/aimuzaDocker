ALTER TABLE public.silk_release_assets
  DROP CONSTRAINT IF EXISTS silk_release_assets_asset_type_check;

ALTER TABLE public.silk_release_assets
  ADD CONSTRAINT silk_release_assets_asset_type_check
  CHECK (
    asset_type IN (
      'master_wav',
      'reference_mp3',
      'cover_art',
      'package_zip',
      'lyrics',
      'license_document',
      'silk_export',
      'admin_attachment'
    )
  );

UPDATE public.silk_releases
SET
  label_name = 'Музыкальный лейбл Нота-Фея',
  platforms = ARRAY['Музыкальный лейбл Нота-Фея']::text[]
WHERE
  label_name IS NULL
  OR label_name IN ('Silk', 'Лейбл Нота-Фея')
  OR platforms = ARRAY['Silk']::text[];
