import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://aimuza.ru",
  "http://localhost",
  "http://localhost:3000",
  "http://localhost:5173",
];

function getCorsHeaders(req: Request) {
  const origin = req.headers.get("origin") || "";
  const allowed = ALLOWED_ORIGINS.some((o) => origin.startsWith(o));
  return {
    "Access-Control-Allow-Origin": allowed ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
  };
}

const YOOKASSA_SHOP_ID = Deno.env.get("YOOKASSA_SHOP_ID") || "";
const YOOKASSA_SECRET_KEY = Deno.env.get("YOOKASSA_SECRET_KEY") || "";

const MIN_AMOUNT = 10;
const MAX_AMOUNT = 150_000;
const ALLOWED_RETURN_HOSTS = ["aimuza.ru", "localhost"];

serve(async (req) => {
  const cors = getCorsHeaders(req);

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: cors });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // --- Auth ---
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return json(cors, 401, { error: "Необходима авторизация" });
    }

    const token = authHeader.replace("Bearer ", "");
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return json(cors, 401, { error: "Неверный токен авторизации" });
    }

    // --- Validate input ---
    const body = await req.json();
    const amount = Number(body.amount);

    if (!Number.isFinite(amount) || !Number.isInteger(amount)) {
      return json(cors, 400, { error: "Сумма должна быть целым числом" });
    }
    if (amount < MIN_AMOUNT) {
      return json(cors, 400, {
        error: `Минимальная сумма пополнения: ${MIN_AMOUNT} ₽`,
      });
    }
    if (amount > MAX_AMOUNT) {
      return json(cors, 400, {
        error: `Максимальная сумма пополнения: ${MAX_AMOUNT} ₽`,
      });
    }

    // --- Validate return_url ---
    const safeReturnUrl = sanitizeReturnUrl(
      body.return_url,
      req.headers.get("origin")
    );

    const description =
      typeof body.description === "string" && body.description.length <= 200
        ? body.description
        : `Пополнение баланса на ${amount} ₽`;

    // --- Create payment record ---
    const { data: payment, error: paymentError } = await supabase
      .from("payments")
      .insert({
        user_id: user.id,
        amount,
        currency: "RUB",
        status: "pending",
        payment_system: "yookassa",
        description,
      })
      .select()
      .single();

    if (paymentError) {
      console.error("DB insert error:", paymentError);
      return json(cors, 500, { error: "Ошибка создания платежа" });
    }

    // --- Create YooKassa payment ---
    const idempotenceKey = crypto.randomUUID();

    const yooKassaPayload = {
      amount: { value: amount.toFixed(2), currency: "RUB" },
      capture: true,
      confirmation: { type: "redirect", return_url: safeReturnUrl },
      description,
      metadata: { payment_id: payment.id, user_id: user.id },
    };

    const response = await fetch("https://api.yookassa.ru/v3/payments", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Idempotence-Key": idempotenceKey,
        Authorization: `Basic ${btoa(`${YOOKASSA_SHOP_ID}:${YOOKASSA_SECRET_KEY}`)}`,
      },
      body: JSON.stringify(yooKassaPayload),
    });

    if (!response.ok) {
      const errText = await response.text();
      console.error("YooKassa API error:", response.status, errText);
      // Откатываем запись
      await supabase.from("payments").delete().eq("id", payment.id);
      return json(cors, 502, { error: "Ошибка создания платежа в ЮKassa" });
    }

    const yooResponse = await response.json();

    // --- Save external_id ---
    await supabase
      .from("payments")
      .update({ external_id: yooResponse.id, metadata: yooResponse })
      .eq("id", payment.id);

    return json(cors, 200, {
      success: true,
      payment_id: payment.id,
      payment_url: yooResponse.confirmation.confirmation_url,
    });
  } catch (error: unknown) {
    console.error("YooKassa create error:", error);
    return json(getCorsHeaders(req), 500, { error: "Внутренняя ошибка сервера" });
  }
});

// --- Helpers ---

function json(
  cors: Record<string, string>,
  status: number,
  data: Record<string, unknown>
) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function sanitizeReturnUrl(
  rawUrl: unknown,
  origin: string | null
): string {
  const fallback = `${origin || "https://aimuza.ru"}/profile?payment=success`;

  if (typeof rawUrl !== "string" || rawUrl.length > 500) return fallback;

  try {
    const url = new URL(rawUrl);
    const isAllowed = ALLOWED_RETURN_HOSTS.some(
      (h) => url.hostname === h || url.hostname.endsWith(`.${h}`)
    );
    return isAllowed ? rawUrl : fallback;
  } catch {
    return fallback;
  }
}
