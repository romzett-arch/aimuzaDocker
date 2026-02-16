-- Fix notify_table_change: use octet_length instead of length
-- length() counts CHARACTERS, pg_notify limits BYTES (8000)
-- Russian UTF-8 chars = 2 bytes each, so 7500 chars ≈ 15000 bytes > 8000 limit
-- This caused track UPDATE failures when description/lyrics were long

CREATE OR REPLACE FUNCTION notify_table_change() RETURNS TRIGGER AS $$
DECLARE
  payload jsonb;
  record_data jsonb;
  op text;
BEGIN
  op := TG_OP;

  IF op = 'DELETE' THEN
    record_data := to_jsonb(OLD);
  ELSE
    record_data := to_jsonb(NEW);
  END IF;

  -- Build full payload
  payload := jsonb_build_object(
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA,
    'type', op,
    'record', record_data,
    'old_record', CASE WHEN op = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END
  );

  -- CRITICAL: octet_length (bytes) not length (characters)
  -- pg_notify has 8000 BYTE limit
  IF octet_length(payload::text) > 7500 THEN
    payload := jsonb_build_object(
      'table', TG_TABLE_NAME,
      'schema', TG_TABLE_SCHEMA,
      'type', op,
      'record', jsonb_build_object(
        'id', CASE WHEN op = 'DELETE' THEN OLD.id ELSE NEW.id END
      ),
      'old_record', NULL
    );
  END IF;

  PERFORM pg_notify('table_changes', payload::text);

  IF op = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
