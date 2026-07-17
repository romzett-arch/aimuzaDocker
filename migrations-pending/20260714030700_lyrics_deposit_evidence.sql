ALTER TABLE public.lyrics_deposits
  ADD COLUMN IF NOT EXISTS evidence_version text NOT NULL DEFAULT 'legacy-v0',
  ADD COLUMN IF NOT EXISTS work_title_snapshot text,
  ADD COLUMN IF NOT EXISTS proof_status text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS external_proof text;

COMMENT ON COLUMN public.lyrics_deposits.content_hash IS
  'SHA-256 of the canonical work payload. For aimuza-lyrics-v1: AIMUZA-LYRICS-V1 + LF + NFC title + LF + NFC content with CRLF normalized.';
COMMENT ON COLUMN public.lyrics_deposits.timestamp_hash IS
  'Server HMAC-SHA-256 signature of the evidence record; not a blockchain transaction hash.';
COMMENT ON COLUMN public.lyrics_deposits.external_proof IS
  'External provider proof payload. OpenTimestamps detached proof is stored as base64 while awaiting Bitcoin confirmation.';

UPDATE public.lyrics_deposits
SET proof_status = CASE
      WHEN method = 'blockchain' AND COALESCE(external_id, '') LIKE 'ots_pending_%' THEN 'pending_external'
      WHEN status = 'completed' THEN 'legacy_unverified'
      ELSE 'none'
    END
WHERE evidence_version = 'legacy-v0';
