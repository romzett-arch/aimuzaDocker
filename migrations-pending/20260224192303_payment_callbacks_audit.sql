-- Таблица аудита callback-запросов от платёжных систем
CREATE TABLE IF NOT EXISTS payment_callbacks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_system TEXT NOT NULL,
  inv_id TEXT NOT NULL,
  out_sum TEXT,
  signature_valid BOOLEAN NOT NULL DEFAULT false,
  client_ip TEXT,
  raw_params JSONB,
  result TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payment_callbacks_inv_id ON payment_callbacks(inv_id);
CREATE INDEX IF NOT EXISTS idx_payment_callbacks_created_at ON payment_callbacks(created_at);

-- RLS: только сервис может читать/писать
ALTER TABLE payment_callbacks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_only" ON payment_callbacks
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');
