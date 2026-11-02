-- Existing originals are archived without allocating new registration numbers.
ALTER TABLE legal.documents
 ADD COLUMN source text NOT NULL DEFAULT 'created' CHECK(source IN ('created','uploaded')),
 ADD COLUMN document_date date,
 ADD COLUMN is_blank boolean NOT NULL DEFAULT false,
 ADD COLUMN import_key uuid,
 ADD COLUMN import_hash text;
CREATE UNIQUE INDEX legal_document_import_key ON legal.documents(organization_id,import_key) WHERE import_key IS NOT NULL;
CREATE INDEX legal_document_archive_lookup ON legal.documents(organization_id,is_blank,document_date);
