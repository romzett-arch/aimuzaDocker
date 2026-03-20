import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TIMEWEB_AGENT_ACCESS_ID = "e046a9e4-43f6-47bc-a39f-8a9de8778d02";
const MODEL_NAME = "deepseek-v3";
const PROMPT_VERSION = "qa_bug_spec_v1";

type RawBugReport = {
  schemaVersion: "1.0";
  title: string;
  description: string;
  stepsToReproduce?: string;
  expectedBehavior?: string;
  actualBehavior?: string;
  screenshots: string[];
  context: {
    pageUrl?: string;
    userAgent?: string;
    language?: string;
    platform?: string;
    viewport?: string;
    screen?: string;
    category?: string;
    severity?: string;
    createdAt?: string;
  };
};

type DeveloperSpec = {
  shortTitle: string;
  issueSummary: string;
  reproductionSteps: string[];
  actualBehavior: string;
  expectedBehavior: string;
  affectedArea: string;
  verificationScenario: string[];
  sourceMaterials: {
    userTitle: string;
    userDescription: string;
    userSteps?: string;
    userExpected?: string;
    userActual?: string;
    screenshots: string[];
    pageUrl?: string;
    userAgent?: string;
  };
  uncertaintyOrGaps: string[];
  hypotheses: string[];
};

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string" && item.trim().length > 0);
}

function buildRawBugReport(ticket: Record<string, unknown>): RawBugReport {
  const metadata = isPlainObject(ticket.metadata) ? ticket.metadata : {};
  const existing = isPlainObject(metadata.raw_bug_report) ? metadata.raw_bug_report : null;
  if (existing) {
    return existing as RawBugReport;
  }

  return {
    schemaVersion: "1.0",
    title: asString(ticket.title) || "Без названия",
    description: asString(ticket.description) || "Недостаточно данных",
    stepsToReproduce: asString(ticket.steps_to_reproduce),
    expectedBehavior: asString(ticket.expected_behavior),
    actualBehavior: asString(ticket.actual_behavior),
    screenshots: asStringArray(ticket.screenshots),
    context: {
      pageUrl: asString(ticket.page_url),
      userAgent: asString(ticket.user_agent),
      category: asString(ticket.category),
      severity: asString(ticket.severity),
      createdAt: asString(ticket.created_at),
    },
  };
}

function buildFallbackDeveloperSpec(rawReport: RawBugReport): DeveloperSpec {
  return {
    shortTitle: rawReport.title || "Нужно уточнить баг",
    issueSummary: rawReport.description || "Недостаточно данных",
    reproductionSteps: rawReport.stepsToReproduce
      ? rawReport.stepsToReproduce.split("\n").map((step) => step.trim()).filter(Boolean)
      : ["Недостаточно данных"],
    actualBehavior: rawReport.actualBehavior || rawReport.description || "Недостаточно данных",
    expectedBehavior: rawReport.expectedBehavior || "Недостаточно данных",
    affectedArea: rawReport.context.category || "Не указано",
    verificationScenario: rawReport.stepsToReproduce
      ? ["Повторить шаги воспроизведения и сравнить результат с ожидаемым поведением."]
      : ["Собрать недостающие шаги и повторить проблему вручную."],
    sourceMaterials: {
      userTitle: rawReport.title,
      userDescription: rawReport.description,
      userSteps: rawReport.stepsToReproduce,
      userExpected: rawReport.expectedBehavior,
      userActual: rawReport.actualBehavior,
      screenshots: rawReport.screenshots,
      pageUrl: rawReport.context.pageUrl,
      userAgent: rawReport.context.userAgent,
    },
    uncertaintyOrGaps: ["AI не смог подготовить полное ТЗ, используйте исходный репорт."],
    hypotheses: [],
  };
}

function normalizeDeveloperSpec(input: unknown, fallback: RawBugReport): DeveloperSpec {
  if (!isPlainObject(input)) return buildFallbackDeveloperSpec(fallback);

  const sourceMaterials = isPlainObject(input.sourceMaterials) ? input.sourceMaterials : {};
  const fallbackSpec = buildFallbackDeveloperSpec(fallback);

  return {
    shortTitle: asString(input.shortTitle) || fallbackSpec.shortTitle,
    issueSummary: asString(input.issueSummary) || fallbackSpec.issueSummary,
    reproductionSteps: asStringArray(input.reproductionSteps).length
      ? asStringArray(input.reproductionSteps)
      : fallbackSpec.reproductionSteps,
    actualBehavior: asString(input.actualBehavior) || fallbackSpec.actualBehavior,
    expectedBehavior: asString(input.expectedBehavior) || fallbackSpec.expectedBehavior,
    affectedArea: asString(input.affectedArea) || fallbackSpec.affectedArea,
    verificationScenario: asStringArray(input.verificationScenario).length
      ? asStringArray(input.verificationScenario)
      : fallbackSpec.verificationScenario,
    sourceMaterials: {
      userTitle: asString(sourceMaterials.userTitle) || fallback.title,
      userDescription: asString(sourceMaterials.userDescription) || fallback.description,
      userSteps: asString(sourceMaterials.userSteps) || fallback.stepsToReproduce,
      userExpected: asString(sourceMaterials.userExpected) || fallback.expectedBehavior,
      userActual: asString(sourceMaterials.userActual) || fallback.actualBehavior,
      screenshots: asStringArray(sourceMaterials.screenshots).length
        ? asStringArray(sourceMaterials.screenshots)
        : fallback.screenshots,
      pageUrl: asString(sourceMaterials.pageUrl) || fallback.context.pageUrl,
      userAgent: asString(sourceMaterials.userAgent) || fallback.context.userAgent,
    },
    uncertaintyOrGaps: asStringArray(input.uncertaintyOrGaps),
    hypotheses: asStringArray(input.hypotheses),
  };
}

async function saveAiResult(adminClient: ReturnType<typeof createClient>, ticketId: string, metadata: Record<string, unknown>) {
  const { error } = await adminClient
    .from("qa_tickets")
    .update({ metadata, updated_at: new Date().toISOString() })
    .eq("id", ticketId);

  if (error) {
    throw error;
  }
}

async function generateWithDeepSeek(rawReport: RawBugReport, timewebToken: string): Promise<DeveloperSpec> {
  const systemPrompt = `Ты готовишь ТЗ для разработчика по багрепорту музыкальной платформы AIMUZA.
Верни СТРОГО JSON без markdown и без пояснений.

Формат ответа:
{
  "shortTitle": "краткое инженерное название",
  "issueSummary": "1-3 предложения по сути проблемы",
  "reproductionSteps": ["шаг 1", "шаг 2"],
  "actualBehavior": "что происходит сейчас",
  "expectedBehavior": "что должно происходить",
  "affectedArea": "какая подсистема затронута",
  "verificationScenario": ["как проверить исправление"],
  "sourceMaterials": {
    "userTitle": "оригинальный заголовок",
    "userDescription": "оригинальное описание",
    "userSteps": "оригинальные шаги",
    "userExpected": "оригинальное ожидаемое",
    "userActual": "оригинальное фактическое",
    "screenshots": ["url"],
    "pageUrl": "url",
    "userAgent": "ua"
  },
  "uncertaintyOrGaps": ["чего не хватает"],
  "hypotheses": ["осторожные гипотезы, если есть"]
}

Правила:
- Не выдумывай факты.
- Если данных нет, пиши "Недостаточно данных".
- Не ставь диагноз как факт.
- Сохраняй важные детали из оригинала.
- reproductionSteps и verificationScenario всегда массивы строк.`;

  const userPrompt = JSON.stringify(rawReport);
  const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;
  const response = await fetch(apiUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${timewebToken}`,
    },
    body: JSON.stringify({
      model: MODEL_NAME,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      temperature: 0.1,
      max_tokens: 900,
    }),
  });

  if (!response.ok) {
    throw new Error(`AI service unavailable (${response.status})`);
  }

  const data = await response.json();
  const text = data.choices?.[0]?.message?.content?.trim();
  if (!text) {
    throw new Error("AI вернул пустой ответ");
  }

  const jsonMatch = text.match(/\{[\s\S]*\}/);
  const parsed = jsonMatch ? JSON.parse(jsonMatch[0]) : JSON.parse(text);
  return normalizeDeveloperSpec(parsed, rawReport);
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const timewebToken = Deno.env.get("TIMEWEB_AGENT_TOKEN");

    if (!timewebToken) {
      return new Response(JSON.stringify({ error: "TIMEWEB_AGENT_TOKEN not configured" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const ticketId = asString(body.ticketId);
    const force = body.force === true;

    if (!ticketId) {
      return new Response(JSON.stringify({ error: "ticketId is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: roleCheck } = await adminClient.rpc("has_role", {
      _user_id: authData.user.id,
      _role: "admin",
    });
    const { data: superCheck } = await adminClient.rpc("has_role", {
      _user_id: authData.user.id,
      _role: "super_admin",
    });
    const isAdmin = Boolean(roleCheck) || Boolean(superCheck);

    const { data: ticket, error: ticketError } = await adminClient
      .from("qa_tickets")
      .select("id, reporter_id, ticket_number, title, description, steps_to_reproduce, expected_behavior, actual_behavior, screenshots, page_url, user_agent, category, severity, created_at, metadata")
      .eq("id", ticketId)
      .single();

    if (ticketError || !ticket) {
      return new Response(JSON.stringify({ error: "Ticket not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!isAdmin && ticket.reporter_id !== authData.user.id) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const metadata = isPlainObject(ticket.metadata) ? { ...ticket.metadata } : {};
    const existingAi = isPlainObject(metadata.ai_bug_report) ? metadata.ai_bug_report : null;
    const rawReport = buildRawBugReport(ticket as Record<string, unknown>);

    if (!force && existingAi && isPlainObject(existingAi.developerSpec)) {
      return new Response(JSON.stringify({
        success: true,
        ticketId,
        rawReport,
        developerSpec: existingAi.developerSpec,
        aiBugReport: existingAi,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    try {
      const developerSpec = await generateWithDeepSeek(rawReport, timewebToken);
      const aiBugReport = {
        status: "ready",
        promptVersion: PROMPT_VERSION,
        model: MODEL_NAME,
        generatedAt: new Date().toISOString(),
        error: null,
        rawReport,
        developerSpec,
      };

      await saveAiResult(adminClient, ticketId, {
        ...metadata,
        raw_bug_report: rawReport,
        ai_bug_report: aiBugReport,
      });

      return new Response(JSON.stringify({
        success: true,
        ticketId,
        rawReport,
        developerSpec,
        aiBugReport,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (generationError) {
      const fallbackSpec = buildFallbackDeveloperSpec(rawReport);
      const aiBugReport = {
        status: "error",
        promptVersion: PROMPT_VERSION,
        model: MODEL_NAME,
        generatedAt: new Date().toISOString(),
        error: generationError instanceof Error ? generationError.message : "Unknown error",
        rawReport,
        developerSpec: fallbackSpec,
      };

      await saveAiResult(adminClient, ticketId, {
        ...metadata,
        raw_bug_report: rawReport,
        ai_bug_report: aiBugReport,
      });

      return new Response(JSON.stringify({
        success: false,
        ticketId,
        rawReport,
        developerSpec: fallbackSpec,
        aiBugReport,
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  } catch (error) {
    console.error("[qa-generate-spec] Error:", error);
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
