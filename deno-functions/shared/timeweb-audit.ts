type AuditContext = {
  source: string;
  action: string;
  reason: string;
  entityType?: string;
  entityId?: string;
};

type TokenUsage = {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
};

function getAuditHeaders() {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };
}

function describeRequest(init?: RequestInit) {
  if (typeof init?.body !== "string") return {};
  try {
    const payload = JSON.parse(init.body);
    const messages = Array.isArray(payload.messages) ? payload.messages : [];
    return {
      model: typeof payload.model === "string" ? payload.model : null,
      request_chars: messages.reduce(
        (sum: number, message: { content?: unknown }) =>
          sum + (typeof message?.content === "string" ? message.content.length : 0),
        0,
      ),
      request_messages: messages.length,
      max_tokens: typeof payload.max_tokens === "number" ? payload.max_tokens : null,
    };
  } catch {
    return {};
  }
}

async function insertAudit(context: AuditContext, request: Record<string, unknown>) {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!supabaseUrl || !Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return null;

  const id = crypto.randomUUID();
  const response = await fetch(`${supabaseUrl}/rest/v1/ai_request_logs`, {
    method: "POST",
    headers: { ...getAuditHeaders(), Prefer: "return=minimal" },
    body: JSON.stringify({
      id,
      provider: "timeweb",
      source: context.source,
      action: context.action,
      reason: context.reason,
      entity_type: context.entityType || null,
      entity_id: context.entityId || null,
      status: "started",
      ...request,
    }),
  });

  if (!response.ok) {
    console.warn(`[timeweb-audit] Cannot create log: ${response.status}`);
    return null;
  }
  return id;
}

async function updateAudit(id: string | null, values: Record<string, unknown>) {
  if (!id) return;
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!supabaseUrl) return;
  const response = await fetch(`${supabaseUrl}/rest/v1/ai_request_logs?id=eq.${id}`, {
    method: "PATCH",
    headers: getAuditHeaders(),
    body: JSON.stringify({ ...values, finished_at: new Date().toISOString() }),
  });
  if (!response.ok) console.warn(`[timeweb-audit] Cannot update log ${id}: ${response.status}`);
}

export async function loggedTimewebFetch(
  context: AuditContext,
  input: string | URL,
  init?: RequestInit,
): Promise<Response> {
  const startedAt = Date.now();
  const requestInfo = describeRequest(init);
  let auditId: string | null = null;

  try {
    auditId = await insertAudit(context, requestInfo);
  } catch (error) {
    console.warn("[timeweb-audit] Pre-request logging failed:", error);
  }

  console.log(`[timeweb-audit] ${context.source}/${context.action}: ${context.reason}`);

  try {
    const response = await fetch(input, init);
    let usage: TokenUsage = {};
    try {
      const payload = await response.clone().json();
      usage = payload?.usage || {};
    } catch {
      // Some error responses are not JSON.
    }

    await updateAudit(auditId, {
      status: response.ok ? "completed" : "failed",
      http_status: response.status,
      prompt_tokens: usage.prompt_tokens ?? null,
      completion_tokens: usage.completion_tokens ?? null,
      total_tokens: usage.total_tokens ?? null,
      duration_ms: Date.now() - startedAt,
      error: response.ok ? null : `Timeweb HTTP ${response.status}`,
    }).catch((error) => console.warn("[timeweb-audit] Post-request logging failed:", error));

    return response;
  } catch (error) {
    await updateAudit(auditId, {
      status: "failed",
      duration_ms: Date.now() - startedAt,
      error: error instanceof Error ? error.message : String(error),
    }).catch(() => undefined);
    throw error;
  }
}
