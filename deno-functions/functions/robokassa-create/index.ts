import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildBankCardInvoicePayload, createInvoiceJwt } from "./invoice.ts";

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
const ROBOKASSA_INVOICE_URL =
  "https://services.robokassa.ru/InvoiceServiceWebApi/api/CreateInvoice";
const ALLOWED_RETURN_HOSTS = ["aimuza.ru"];

function getMissingRequiredEnvNames() {
  const requiredEnv = {
    SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
    ROBOKASSA_MERCHANT_LOGIN,
    ROBOKASSA_PASSWORD1,
  };

  return Object.entries(requiredEnv)
    .filter(([, value]) => !value || !value.trim())
    .map(([name]) => name);
}

function leftRotate(value: number, amount: number): number {
  return (value << amount) | (value >>> (32 - amount));
}

function computeMD5(str: string): string {
  const data = Array.from(new TextEncoder().encode(str));
  const bitLength = data.length * 8;
  data.push(0x80);

  while (data.length % 64 !== 56) {
    data.push(0);
  }

  for (let i = 0; i < 8; i++) {
    data.push(Math.floor(bitLength / 2 ** (8 * i)) & 0xff);
  }

  let a0 = 0x67452301;
  let b0 = 0xefcdab89;
  let c0 = 0x98badcfe;
  let d0 = 0x10325476;

  const shifts = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  const constants = Array.from({ length: 64 }, (_, i) =>
    Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0
  );

  for (let offset = 0; offset < data.length; offset += 64) {
    const words = Array.from({ length: 16 }, (_, i) => {
      const index = offset + i * 4;
      return (
        data[index] |
        (data[index + 1] << 8) |
        (data[index + 2] << 16) |
        (data[index + 3] << 24)
      ) >>> 0;
    });

    let a = a0;
    let b = b0;
    let c = c0;
    let d = d0;

    for (let i = 0; i < 64; i++) {
      let f: number;
      let g: number;

      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }

      const next = d;
      d = c;
      c = b;
      b = (b + leftRotate((a + f + constants[i] + words[g]) >>> 0, shifts[i])) >>> 0;
      a = next;
    }

    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  return [a0, b0, c0, d0]
    .flatMap((word) => [word & 0xff, (word >>> 8) & 0xff, (word >>> 16) & 0xff, (word >>> 24) & 0xff])
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

// Робокасса InvId: числовой ID из последовательности, хранится как external_id
// Вместо обрезки UUID используем timestamp + random для уникальности
function generateInvId(): string {
  const min = 100_000_000;
  const max = 2_147_483_647;
  return String(Math.floor(Math.random() * (max - min + 1)) + min);
}

serve(async (req) => {
  const cors = getCorsHeaders(req);

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: cors });
  }

  try {
    const missingEnvNames = getMissingRequiredEnvNames();
    if (missingEnvNames.length > 0) {
      console.error("Robokassa create config error:", {
        missingEnvNames,
      });
      return json(cors, 503, {
        error: "Платёжный шлюз Robokassa временно не настроен. Обратитесь к администратору.",
        code: "robokassa_not_configured",
      });
    }

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
    const paymentMethod = body.payment_method === undefined
      ? "sbp"
      : body.payment_method;

    if (paymentMethod !== "bank_card" && paymentMethod !== "sbp") {
      return json(cors, 400, { error: "Неподдерживаемый способ оплаты" });
    }

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
        metadata: { method: paymentMethod },
      })
      .select()
      .single();

    if (paymentError) {
      console.error("DB insert error:", paymentError);
      return json(cors, 500, { error: "Ошибка создания платежа" });
    }

    // --- Receipt для фискализации 54-ФЗ ---
    const receipt = JSON.stringify({
      sno: "usn_income",
      items: [
        {
          name: description.slice(0, 128),
          quantity: 1,
          sum: amount,
          payment_method: "full_payment",
          payment_object: "service",
          tax: "none",
        },
      ],
    });
    const outSum = String(amount);

    if (paymentMethod === "bank_card") {
      const returnUrl = sanitizeReturnUrl(body.return_url, req.headers.get("origin"));
      const invoicePayload = buildBankCardInvoicePayload({
        merchantLogin: ROBOKASSA_MERCHANT_LOGIN,
        invId,
        amount,
        description,
        email: user.email || "",
        successUrl: returnUrl,
        failUrl: returnUrl,
        isTest: ROBOKASSA_TEST_MODE,
      });
      const invoiceJwt = createInvoiceJwt(
        invoicePayload,
        ROBOKASSA_MERCHANT_LOGIN,
        ROBOKASSA_PASSWORD1,
      );
      const invoiceResponse = await fetch(ROBOKASSA_INVOICE_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(invoiceJwt),
      });
      const invoiceResult = await invoiceResponse.json().catch(() => null) as {
        id?: string;
        invId?: number;
        url?: string;
        isSuccess?: boolean;
        message?: string;
      } | null;

      if (
        !invoiceResponse.ok ||
        !invoiceResult?.isSuccess ||
        !invoiceResult.url ||
        Number(invoiceResult.invId) !== Number(invId)
      ) {
        console.error("Robokassa Invoice API error:", {
          status: invoiceResponse.status,
          isSuccess: invoiceResult?.isSuccess,
          message: invoiceResult?.message,
        });
        await supabase
          .from("payments")
          .update({
            status: "failed",
            metadata: {
              method: "bank_card",
              invoice_error: invoiceResult?.message || `HTTP ${invoiceResponse.status}`,
            },
            updated_at: new Date().toISOString(),
          })
          .eq("id", payment.id);
        return json(cors, 502, { error: "Не удалось создать оплату банковской картой" });
      }

      await supabase
        .from("payments")
        .update({
          metadata: {
            method: "bank_card",
            invoice_id: invoiceResult.id,
          },
        })
        .eq("id", payment.id);

      return json(cors, 200, {
        success: true,
        payment_id: payment.id,
        payment_method: "bank_card",
        payment_url: invoiceResult.url,
      });
    }

    // --- Подпись для Robokassa.pay.startOp с Receipt ---
    const signatureString =
      `${ROBOKASSA_MERCHANT_LOGIN}:${outSum}:${invId}:${receipt}:${ROBOKASSA_PASSWORD1}`;
    const signature = computeMD5(signatureString);

    return json(cors, 200, {
      success: true,
      payment_id: payment.id,
      payment_method: "sbp",
      qr_options: {
        paymentMethod: "SBP",
        email: user.email || "",
        merchantLogin: ROBOKASSA_MERCHANT_LOGIN,
        outSum: amount,
        invId: Number(invId),
        receipt,
        signature,
        isTest: ROBOKASSA_TEST_MODE ? 1 : 0,
      },
    });
  } catch (error: unknown) {
    console.error("Robokassa create error:", error);
    return json(getCorsHeaders(req), 500, { error: "Внутренняя ошибка сервера" });
  }
});

function sanitizeReturnUrl(rawUrl: unknown, origin: string | null): string {
  const fallbackOrigin = origin && isAllowedPublicOrigin(origin)
    ? origin
    : "https://aimuza.ru";
  const fallback = `${fallbackOrigin}/profile`;
  if (typeof rawUrl !== "string" || rawUrl.length > 500) return fallback;

  try {
    const url = new URL(rawUrl);
    const isAllowed = url.protocol === "https:" && ALLOWED_RETURN_HOSTS.some(
      (host) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
    if (!isAllowed) return fallback;

    // Robokassa Invoice API rejects otherwise valid return URLs when they
    // contain query parameters or a fragment ("Url был сформирован некорректно").
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return fallback;
  }
}

function isAllowedPublicOrigin(origin: string): boolean {
  try {
    const url = new URL(origin);
    return url.protocol === "https:" && ALLOWED_RETURN_HOSTS.some(
      (host) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
  } catch {
    return false;
  }
}

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
