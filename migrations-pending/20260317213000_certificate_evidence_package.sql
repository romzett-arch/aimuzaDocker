ALTER TABLE public.track_deposits
ADD COLUMN IF NOT EXISTS pdf_url TEXT,
ADD COLUMN IF NOT EXISTS certificate_html_hash TEXT,
ADD COLUMN IF NOT EXISTS certificate_pdf_hash TEXT,
ADD COLUMN IF NOT EXISTS registry_url TEXT,
ADD COLUMN IF NOT EXISTS blockchain_proof_path TEXT,
ADD COLUMN IF NOT EXISTS blockchain_proof_url TEXT,
ADD COLUMN IF NOT EXISTS blockchain_proof_status TEXT,
ADD COLUMN IF NOT EXISTS blockchain_submitted_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS certificate_generated_at TIMESTAMP WITH TIME ZONE;
