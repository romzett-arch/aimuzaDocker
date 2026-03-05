-- Обновление цены депонирования через blockchain с 10 до 300 ₽.

INSERT INTO public.settings (key, value, description)
VALUES ('deposit_price_blockchain', '300', 'Цена депонирования через OpenTimestamps (blockchain), ₽')
ON CONFLICT (key) DO UPDATE SET value = '300', updated_at = now();
