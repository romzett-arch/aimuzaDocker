INSERT INTO public.addon_services
  (name, name_ru, description, price_rub, base_cost_credits, icon, sort_order,
   provider, provider_operation, provider_model, provider_options, is_active)
VALUES
  ('generate_image', 'Создание картинки', 'Одно изображение из описания в Seedream',
   5, 1.98, 'image', 99, 'routerai', 'images', 'bytedance-seed/seedream-5-0-flash',
   '{"estimated_cost_rub":1.98}', true)
ON CONFLICT (name) DO NOTHING;

CREATE TABLE public.image_generation_jobs (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  id uuid NOT NULL,
  prompt text NOT NULL,
  aspect_ratio text NOT NULL,
  resolution text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed')),
  price_rub integer NOT NULL DEFAULT 0 CHECK (price_rub >= 0),
  image bytea,
  mime_type text CHECK (mime_type IN ('image/png', 'image/jpeg', 'image/webp')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, id)
);

ALTER TABLE public.image_generation_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.image_generation_jobs FROM PUBLIC, anon, authenticated;
CREATE INDEX image_generation_history ON public.image_generation_jobs (user_id, created_at DESC, id DESC);
CREATE INDEX image_generation_pending ON public.image_generation_jobs (created_at) WHERE status = 'pending';

CREATE FUNCTION public.fail_image_generation(p_user_id uuid, p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE charged integer;
BEGIN
  UPDATE public.image_generation_jobs SET status = 'failed'
  WHERE user_id = p_user_id AND id = p_id AND status = 'pending'
  RETURNING price_rub INTO charged;

  IF charged > 0 AND EXISTS (SELECT 1 FROM public.profiles WHERE user_id = p_user_id) THEN
    PERFORM public.refund_addon_service(
      p_user_id, charged, 'Возврат за создание картинки',
      jsonb_build_object('service_name', 'generate_image', 'request_id', p_id)
    );
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.fail_image_generation(uuid, uuid) FROM PUBLIC, anon, authenticated;
