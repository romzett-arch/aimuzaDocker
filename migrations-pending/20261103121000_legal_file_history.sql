-- Preserve detached originals for historical versions and backup recovery.
ALTER TABLE legal.files ADD COLUMN attached boolean NOT NULL DEFAULT true;
CREATE INDEX legal_attached_files ON legal.files(document_id,attached);
ALTER TABLE legal.memberships ADD COLUMN expiry_notified_at timestamptz;
CREATE TABLE legal.organization_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 revision integer NOT NULL, name text NOT NULL, details text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,revision)
);
INSERT INTO legal.organization_versions(organization_id,revision,name,details)
 SELECT id,revision,name,details FROM legal.organizations;
ALTER TABLE legal.organization_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON legal.organization_versions FROM PUBLIC,anon,authenticated;
CREATE TRIGGER legal_organization_history_immutable BEFORE UPDATE OR DELETE ON legal.organization_versions
 FOR EACH ROW EXECUTE FUNCTION legal.immutable_row();
