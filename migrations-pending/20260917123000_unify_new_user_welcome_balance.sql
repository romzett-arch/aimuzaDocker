-- Keep new-user profile creation and the welcome credit in one trigger/function.
-- Historical migrations used two competing sources (100 in handle_new_user and
-- 50 in fn_grant_welcome_balance), which made the effective starting balance 100.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_welcome_amount CONSTANT integer := 50;
  v_profile_created integer := 0;
BEGIN
  -- Block new registrations during maintenance (fail-closed).
  IF public.is_maintenance_active() THEN
    RAISE EXCEPTION 'Registration is blocked during maintenance'
      USING ERRCODE = 'P0001';
  END IF;

  BEGIN
    INSERT INTO public.profiles (user_id, username, balance)
    VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
      v_welcome_amount
    )
    ON CONFLICT (user_id) DO NOTHING;

    GET DIAGNOSTICS v_profile_created = ROW_COUNT;

    IF v_profile_created = 1 AND v_welcome_amount > 0 THEN
      INSERT INTO public.balance_transactions
        (user_id, amount, type, description, balance_before, balance_after)
      VALUES
        (
          NEW.id,
          v_welcome_amount,
          'bonus',
          format('Приветственный бонус %s₽', v_welcome_amount),
          0,
          v_welcome_amount
        );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user profile creation failed for %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

-- The welcome amount is now owned exclusively by handle_new_user().
DROP TRIGGER IF EXISTS trg_welcome_balance ON auth.users;
DROP FUNCTION IF EXISTS public.fn_grant_welcome_balance();
