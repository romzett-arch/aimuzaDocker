-- Private corporate workspace. No grants to the generic REST/realtime roles.
CREATE SCHEMA IF NOT EXISTS legal;
REVOKE ALL ON SCHEMA legal FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA legal REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA legal REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated;

ALTER TABLE public.api_refresh_sessions ADD COLUMN IF NOT EXISTS session_origin text NOT NULL DEFAULT 'legacy';

CREATE TABLE legal.organizations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL,
 details text NOT NULL DEFAULT '', revision integer NOT NULL DEFAULT 1,
 quota_bytes bigint NOT NULL DEFAULT 10737418240 CHECK(quota_bytes>0),
 created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO legal.organizations(id,name) VALUES ('a1000000-0000-4000-8000-000000000001','АИМУЗА');
CREATE TABLE legal.memberships (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 user_id uuid NOT NULL REFERENCES auth.users, profile text NOT NULL CHECK(profile IN ('lawyer','viewer')),
 scope text NOT NULL CHECK(scope IN ('all','cases')), manage_templates boolean NOT NULL DEFAULT false,
 expires_at timestamptz, revoked_at timestamptz, granted_by uuid NOT NULL REFERENCES auth.users,
 revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(organization_id,user_id)
);
CREATE TABLE legal.parties (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 300), details text NOT NULL DEFAULT '',
 revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,id)
);
CREATE TABLE legal.cases (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 300), description text NOT NULL DEFAULT '',
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','in_progress','closed','archived')),
 party_id uuid, responsible_id uuid REFERENCES auth.users, revision integer NOT NULL DEFAULT 1,
 created_by uuid NOT NULL REFERENCES auth.users, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(organization_id,id), FOREIGN KEY(organization_id,party_id) REFERENCES legal.parties(organization_id,id)
);
CREATE TABLE legal.case_members (
 organization_id uuid NOT NULL REFERENCES legal.organizations, case_id uuid NOT NULL,
 user_id uuid NOT NULL REFERENCES auth.users, PRIMARY KEY(case_id,user_id),
 FOREIGN KEY(organization_id,case_id) REFERENCES legal.cases(organization_id,id),
 FOREIGN KEY(organization_id,user_id) REFERENCES legal.memberships(organization_id,user_id)
);
CREATE TABLE legal.appointments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 user_id uuid NOT NULL REFERENCES auth.users, appointed_by uuid NOT NULL REFERENCES auth.users,
 profile text NOT NULL CHECK(profile IN ('lawyer','viewer')), scope text NOT NULL CHECK(scope IN ('all','cases')),
 case_ids uuid[] NOT NULL DEFAULT '{}', manage_templates boolean NOT NULL DEFAULT false,
 access_expires_at timestamptz, expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
 message text NOT NULL DEFAULT '', reason text NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','declined','cancelled','expired')),
 responded_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX legal_one_pending_appointment ON legal.appointments(organization_id,user_id) WHERE status='pending';
CREATE TABLE legal.templates (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 title text NOT NULL, revision integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,id)
);
CREATE TABLE legal.template_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
 template_id uuid NOT NULL, revision integer NOT NULL, body text NOT NULL DEFAULT '',
 header text NOT NULL DEFAULT 'АИМУЗА', footer text NOT NULL DEFAULT '',
 created_by uuid REFERENCES auth.users, created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(organization_id,template_id) REFERENCES legal.templates(organization_id,id), UNIQUE(template_id,revision), UNIQUE(organization_id,id)
);
WITH t AS (INSERT INTO legal.templates(organization_id,title) VALUES
 ('a1000000-0000-4000-8000-000000000001','Фирменный бланк АИМУЗА') RETURNING id,organization_id)
INSERT INTO legal.template_versions(organization_id,template_id,revision) SELECT organization_id,id,1 FROM t;
CREATE TABLE legal.documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 case_id uuid, party_id uuid, template_version_id uuid, related_document_id uuid,
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 300), kind text NOT NULL DEFAULT 'letter' CHECK(kind IN ('letter','claim','contract','other')),
 direction text NOT NULL DEFAULT 'outgoing' CHECK(direction IN ('outgoing','incoming','internal')),
 recipient text NOT NULL DEFAULT '', external_number text NOT NULL DEFAULT '', received_at date,
 body text NOT NULL DEFAULT '', status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','registered','archived','annulled','deleted')),
 revision integer NOT NULL DEFAULT 1, created_by uuid NOT NULL REFERENCES auth.users,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(organization_id,id),
 FOREIGN KEY(organization_id,case_id) REFERENCES legal.cases(organization_id,id),
 FOREIGN KEY(organization_id,party_id) REFERENCES legal.parties(organization_id,id),
 FOREIGN KEY(organization_id,template_version_id) REFERENCES legal.template_versions(organization_id,id),
 FOREIGN KEY(organization_id,related_document_id) REFERENCES legal.documents(organization_id,id)
);
CREATE TABLE legal.document_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, document_id uuid NOT NULL,
 revision integer NOT NULL, snapshot jsonb NOT NULL, created_by uuid NOT NULL REFERENCES auth.users,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(document_id,revision), UNIQUE(organization_id,id),
 FOREIGN KEY(organization_id,document_id) REFERENCES legal.documents(organization_id,id)
);
CREATE TABLE legal.files (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, document_id uuid NOT NULL,
 name text NOT NULL, storage_key text NOT NULL UNIQUE, mime text NOT NULL, size bigint NOT NULL CHECK(size>0), sha256 text NOT NULL,
 purpose text NOT NULL CHECK(purpose IN ('original','attachment','signed','proof','pdf')),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','ready','rejected')),
 created_by uuid REFERENCES auth.users, created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(organization_id,document_id) REFERENCES legal.documents(organization_id,id)
);
CREATE TABLE legal.register_counters (
 organization_id uuid NOT NULL REFERENCES legal.organizations, direction text NOT NULL,
 year integer NOT NULL, last_number integer NOT NULL CHECK(last_number>0), PRIMARY KEY(organization_id,direction,year)
);
CREATE TABLE legal.register_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, document_id uuid NOT NULL UNIQUE,
 version_id uuid NOT NULL, direction text NOT NULL, year integer NOT NULL, sequence integer NOT NULL,
 number text NOT NULL, registered_by uuid NOT NULL REFERENCES auth.users, registered_at timestamptz NOT NULL DEFAULT now(),
 idempotency_key uuid NOT NULL, request_hash text NOT NULL, annul_reason text,
 FOREIGN KEY(organization_id,document_id) REFERENCES legal.documents(organization_id,id),
 FOREIGN KEY(organization_id,version_id) REFERENCES legal.document_versions(organization_id,id),
 UNIQUE(organization_id,direction,year,sequence), UNIQUE(organization_id,idempotency_key)
);
CREATE TABLE legal.correspondence_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, document_id uuid NOT NULL,
 type text NOT NULL CHECK(type IN ('sent','delivered','received','response')), method text NOT NULL,
 occurred_at timestamptz NOT NULL, notes text NOT NULL DEFAULT '', created_by uuid NOT NULL REFERENCES auth.users,
 created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(organization_id,document_id) REFERENCES legal.documents(organization_id,id)
);
CREATE TABLE legal.tasks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, case_id uuid, document_id uuid,
 title text NOT NULL, responsible_id uuid NOT NULL REFERENCES auth.users, due_at timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','cancelled')), result text NOT NULL DEFAULT '',
 revision integer NOT NULL DEFAULT 1, reminded_at timestamptz, created_by uuid NOT NULL REFERENCES auth.users,
 created_at timestamptz NOT NULL DEFAULT now(), CHECK(case_id IS NOT NULL OR document_id IS NOT NULL),
 FOREIGN KEY(organization_id,case_id) REFERENCES legal.cases(organization_id,id),
 FOREIGN KEY(organization_id,document_id) REFERENCES legal.documents(organization_id,id)
);
CREATE TABLE legal.audit_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES legal.organizations,
 actor_id uuid REFERENCES auth.users, action text NOT NULL, object_type text NOT NULL, object_id uuid,
 case_id uuid, metadata jsonb NOT NULL DEFAULT '{}', request_id uuid NOT NULL DEFAULT gen_random_uuid(),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE legal.jobs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), document_id uuid REFERENCES legal.documents,
 file_id uuid REFERENCES legal.files, type text NOT NULL CHECK(type IN ('pdf','scan')),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','ready','failed')),
 attempts integer NOT NULL DEFAULT 0, available_at timestamptz NOT NULL DEFAULT now(), lease_until timestamptz,
 last_error text, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(type,document_id,file_id)
);
CREATE UNIQUE INDEX legal_one_pdf_job ON legal.jobs(document_id) WHERE type='pdf';
CREATE INDEX legal_documents_scope ON legal.documents(organization_id,case_id,created_at DESC);
CREATE INDEX legal_cases_status ON legal.cases(organization_id,status,created_at DESC);
CREATE INDEX legal_tasks_due ON legal.tasks(status,due_at);
CREATE INDEX legal_files_document ON legal.files(document_id,status);
CREATE INDEX legal_audit_scope ON legal.audit_events(organization_id,case_id,created_at DESC);
CREATE INDEX legal_jobs_pending ON legal.jobs(status,available_at);

CREATE FUNCTION legal.immutable_row() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'LEGAL_IMMUTABLE'; END $$;
CREATE TRIGGER legal_versions_immutable BEFORE UPDATE OR DELETE ON legal.document_versions FOR EACH ROW EXECUTE FUNCTION legal.immutable_row();
CREATE TRIGGER legal_templates_immutable BEFORE UPDATE OR DELETE ON legal.template_versions FOR EACH ROW EXECUTE FUNCTION legal.immutable_row();
CREATE TRIGGER legal_audit_immutable BEFORE UPDATE OR DELETE ON legal.audit_events FOR EACH ROW EXECUTE FUNCTION legal.immutable_row();
CREATE FUNCTION legal.protect_document() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'LEGAL_NO_DELETE'; END IF;
 IF OLD.status NOT IN ('draft','deleted') AND
   (to_jsonb(NEW)-'status'-'revision') IS DISTINCT FROM (to_jsonb(OLD)-'status'-'revision') THEN
   RAISE EXCEPTION 'LEGAL_REGISTERED_IMMUTABLE';
 END IF;
 IF OLD.status NOT IN ('draft','deleted') AND NEW.status IN ('draft','deleted') THEN RAISE EXCEPTION 'LEGAL_REGISTERED_IMMUTABLE'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER legal_document_protection BEFORE UPDATE OR DELETE ON legal.documents FOR EACH ROW EXECUTE FUNCTION legal.protect_document();
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='legal' LOOP
  EXECUTE format('ALTER TABLE legal.%I ENABLE ROW LEVEL SECURITY',t.tablename);
  EXECUTE format('REVOKE ALL ON legal.%I FROM PUBLIC, anon, authenticated',t.tablename);
 END LOOP;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA legal FROM PUBLIC, anon, authenticated;
