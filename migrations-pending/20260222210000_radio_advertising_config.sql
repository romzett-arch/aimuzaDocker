-- Add enabled and audio_ad_max_duration_sec to advertising config
UPDATE public.radio_config
SET value = COALESCE(value, '{}'::jsonb)
  || '{"enabled": true, "audio_ad_max_duration_sec": 15}'::jsonb
WHERE key = 'advertising';

-- If advertising row doesn't exist, insert it
INSERT INTO public.radio_config (key, value)
SELECT 'advertising', '{"enabled": true, "audio_ad_slot_every_n_tracks": 5, "skip_price_rub": 5, "skip_ad_price_rub": 5, "audio_ad_max_duration_sec": 15}'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.radio_config WHERE key = 'advertising');

-- Allow admins to manage radio_ad_placements (CRUD)
CREATE POLICY "Admins can select all radio_ad_placements"
ON public.radio_ad_placements FOR SELECT
TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);

CREATE POLICY "Admins can insert radio_ad_placements"
ON public.radio_ad_placements FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);

CREATE POLICY "Admins can update radio_ad_placements"
ON public.radio_ad_placements FOR UPDATE
TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role IN ('admin', 'super_admin'))
);
