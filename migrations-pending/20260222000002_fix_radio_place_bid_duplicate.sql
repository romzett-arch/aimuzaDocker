-- Fix: remove duplicate RPC overloads with numeric signature
-- PostgreSQL had two overloads for each: integer and numeric
-- PostgREST cannot resolve which to call → "is not unique" error
DROP FUNCTION IF EXISTS public.radio_place_bid(uuid, uuid, uuid, numeric);
DROP FUNCTION IF EXISTS public.radio_place_prediction(uuid, uuid, numeric, boolean);
