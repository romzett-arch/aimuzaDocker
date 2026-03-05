import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { crypto as stdCrypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";

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

const ROBOKASSA_MERCHANT_LOGIN = Deno.env.get("ROBOKASSA_MERCHANT_LOGIN") || "";
const ROBOKASSA_PASSWORD1 = Deno.env.get("ROBOKASSA_PASSWORD1") || "";
const ROBOKASSA_TEST_MODE = Deno.env.get("ROBOKASSA_TEST_MODE") === "true";

const MIN_AMOUNT = 10;
const MAX_AMOUNT = 150_000;

async function computeMD5(str: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(str);
  const hashBuffer = await stdCrypto.subtle.digest("MD5", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function generateInvId(): string {
  const numericId = (Date.now() % 1_000_000_000).toString() +
    Math.floor(Math.random() * 1000).toString().padStart(3, "0");
  return numericId;
}

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

    const description =
      typeof body.description === "string" && body.description.length <= 200
        ? body.description
        : `Пополнение баланса на ${amount} ₽`;

    // --- Generate unique InvId ---
    const invId = generateInvId();

    // --- Create payment record ---
    const { data: payment, error: paymentError } = await supabase
      .from("payments")
      .insert({
        user_id: user.id,
        amount,
        currency: "RUB",
        status: "pending",
        payment_system: "robokassa",
        description,
        external_id: invId,
      })
      .select()
      .single();

    if (paymentError) {
      console.error("DB insert error:", paymentError);
      return json(cors, 500, { error: "Ошибка создания платежа" });
    }

    // OutSum в формате "число.00" — Robokassa требует для совпадения подписи
    const outSum = amount.toFixed(2);

    // --- Подпись: MD5(MerchantLogin:OutSum:InvId:Password1) ---
    const signatureString =
      `${ROBOKASSA_MERCHANT_LOGIN}:${outSum}:${invId}:${ROBOKASSA_PASSWORD1}`;
    const signature = await computeMD5(signatureString);

    const signInputForLog = `${ROBOKASSA_MERCHANT_LOGIN}:${outSum}:${invId}:[PASSWORD]`;
    console.log("Robokassa create:", { invId, outSum, amount, merchant: ROBOKASSA_MERCHANT_LOGIN, isTest: ROBOKASSA_TEST_MODE, signInput: signInputForLog, signature });

    // --- Build payment URL ---
    const paymentUrl = "https://auth.robokassa.ru/Merchant/Index.aspx";
    const paymentParams: Record<string, string> = {
      MerchantLogin: ROBOKASSA_MERCHANT_LOGIN,
      OutSum: outSum,
      InvId: invId,
      Description: description.slice(0, 100),
      SignatureValue: signature,
      IsTest: ROBOKASSA_TEST_MODE ? "1" : "0",
      Culture: "ru",
    };

    return json(cors, 200, {
      success: true,
      payment_id: payment.id,
      payment_url: paymentUrl,
      payment_params: paymentParams,
    });
  } catch (error: unknown) {
    console.error("Robokassa create error:", error);
    return json(getCorsHeaders(req), 500, { error: "Внутренняя ошибка сервера" });
  }
});

function json(
  cors: Record<string, string>,
  status: number,
  data: Record<string, unknown>
) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8" },
  });
}