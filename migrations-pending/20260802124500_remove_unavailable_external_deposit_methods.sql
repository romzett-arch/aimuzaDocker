DELETE FROM public.settings
WHERE key IN (
  'deposit_price_nris',
  'deposit_price_irma',
  'nris_api_url',
  'nris_api_key',
  'irma_api_url',
  'irma_api_key'
);

CREATE OR REPLACE FUNCTION public.get_deposit_method_catalog()
RETURNS TABLE(method text, price integer, available boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    'blockchain'::text AS method,
    CASE WHEN value ~ '^\d+$' THEN value::integer ELSE 300 END AS price,
    true AS available
  FROM (
    SELECT (SELECT value FROM public.settings WHERE key = 'deposit_price_blockchain') AS value
  ) configured;
$$;

REVOKE ALL ON FUNCTION public.get_deposit_method_catalog() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_deposit_method_catalog() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enforce_aimuza_deposit_method()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.method IS DISTINCT FROM 'blockchain' THEN
    RAISE EXCEPTION 'Доступна только цифровая защита AIMUZA';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_aimuza_deposit_method ON public.track_deposits;
CREATE TRIGGER enforce_aimuza_deposit_method
BEFORE INSERT ON public.track_deposits
FOR EACH ROW EXECUTE FUNCTION public.enforce_aimuza_deposit_method();

DROP TRIGGER IF EXISTS enforce_aimuza_deposit_method ON public.lyrics_deposits;
CREATE TRIGGER enforce_aimuza_deposit_method
BEFORE INSERT ON public.lyrics_deposits
FOR EACH ROW EXECUTE FUNCTION public.enforce_aimuza_deposit_method();
