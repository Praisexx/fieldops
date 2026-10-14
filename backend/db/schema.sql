CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE NOT NULL,
  name text NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title text NOT NULL,
  type text NOT NULL,
  customer_name text NOT NULL,
  customer_phone text,
  location text NOT NULL,
  description text NOT NULL,
  status text NOT NULL DEFAULT 'assigned'
    CHECK (status IN ('assigned','accepted','in_progress','completed','declined','cancelled','failed')),
  priority text NOT NULL DEFAULT 'medium' CHECK (priority IN ('low','medium','high','urgent')),
  due_date timestamptz,
  assigned_by text,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  required_fields jsonb NOT NULL DEFAULT '[]',  -- [{key,label}]
  form_data jsonb NOT NULL DEFAULT '{}',
  evidence_required int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS jobs_user_updated ON jobs (user_id, updated_at);

CREATE TABLE IF NOT EXISTS status_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  client_id uuid UNIQUE,
  from_status text NOT NULL,
  to_status text NOT NULL,
  reason text,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS job_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  client_id uuid UNIQUE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- shortcut: file bytes live in Postgres (bytea), fine at capstone scale; move to S3/bucket if volume grows
CREATE TABLE IF NOT EXISTS job_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  client_id uuid UNIQUE,
  kind text NOT NULL CHECK (kind IN ('photo','document','text')),
  filename text,
  mime text,
  size int,
  text_body text,
  data bytea,
  created_at timestamptz NOT NULL DEFAULT now()
);
