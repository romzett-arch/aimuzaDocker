import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://aimuza.ru",
  "http://localhost",
  "http://localhost:3000",
  "http://localhost:5173",
];

const ROBOKASSA_MERCHANT_LOGIN = Deno.env.get("ROBOKASSA_MERCHANT_LOGIN") || "";
const ROBOKASSA_PASSWORD2 = Deno.env.get("ROBOKASSA_PASSWORD2") || "";

function getCorsHeaders(req: Request) {
  const origin = req.headers.get("origin") || "";
  const allowed = ALLOWED_ORIGINS.some((o) => origin.startsWith(o));
  return {
    "Access-Control-Allow-Origin": allowed ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
  };
}

function leftRotate(value: number, amount: number): number {
  return (value << amount) | (value >>> (32 - amount));
}

function computeMD5(str: string): string {
  const data = Array.from(new TextEncoder().encode(str));
  const bitLength = data.length * 8;
  data.push(0x80);

  while (data.length % 64 !== 56) data.push(0);
  for (let i = 0; i < 8; i++) data.push(Math.floor(bitLength / 2 ** (8 * i)) & 0xff);

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

function getXmlValue(xml: string, tagName: string): string | null {
  const match = xml.match(new RegExp(`<${tagName}>([^<]*)</${tagName}>`));
  return match?.[1] ?? null;
}

async function getRobokassaState(invId: string) {
  const signature = computeMD5(`${ROBOKASSA_MERCHANT_LOGIN}:${invId}:${ROBOKASSA_PASSWORD2}`);
  const params = new URLSearchParams({
    MerchantLogin: ROBOKASSA_MERCHANT_LOGIN,
    InvoiceID: invId,
    Signature: signature,
  });
  const response = await fetch(
    `https://auth.robokassa.ru/Merchant/WebService/Service.asmx/OpStateExt?${params.toString()}`
  );
  const xml = await response.text();
  const resultCode = getXmlValue(xml, "Code");
  const stateMatch = xml.match(/<State>[\s\S]*?<Code>([^<]*)<\/Code>/);
  const stateCode = stateMatch?.[1] ?? null;
  const outSum = getXmlValue(xml, "OutSum");

  return {
    ok: response.ok && resultCode === "0",
    resultCode,
    stateCode,
    outSum,
  };
}

serve(async (req) => {
  const cors = getCorsHeaders(req);

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: cors });
  }

  try {
    if (!ROBOKASSA_MERCHANT_LOGIN || !ROBOKASSA_PASSWORD2) {
      return json(cors, 503, { error: "Robokassa is not configured" });
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json(cors, 401, { error: "Необходима авторизация" });

    const body = await req.json();
    const paymentRef = typeof body.payment_id === "string"
      ? body.payment_id.trim()
      : typeof body.inv_id === "string"
        ? body.inv_id.trim()
        : "";
    if (!paymentRef) return json(cors, 400, { error: "payment_id is required" });

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const token = authHeader.replace("Bearer ", "");
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser(token);
    if (authError || !user) return json(cors, 401, { error: "Неверный токен авторизации" });

    const paymentQueryColumn = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(paymentRef)
      ? "id"
      : "external_id";

    const { data: payment, error: paymentError } = await supabase
      .from("payments")
      .select("*")
      .eq(paymentQueryColumn, paymentRef)
      .eq("user_id", user.id)
      .eq("payment_system", "robokassa")
      .single();

    if (paymentError || !payment) {
      console.error("Robokassa check payment not found:", {
        paymentRef,
        paymentQueryColumn,
        userId: user.id,
      });
      return json(cors, 404, { error: "Платёж не найден" });
    }
    if (payment.status === "completed") {
      return json(cors, 200, { success: true, completed: true, amount: payment.amount });
    }
    if (!payment.external_id) return json(cors, 400, { error: "У платежа нет InvId" });

    const state = await getRobokassaState(payment.external_id);
    if (!state.ok) {
      return json(cors, 200, { success: true, completed: false, state });
    }

    if (state.stateCode !== "100") {
      return json(cors, 200, { success: true, completed: false, state });
    }

    const paidAmount = Math.round(Number(state.outSum ?? payment.amount));
    if (paidAmount !== payment.amount) {
      console.error("Robokassa check amount mismatch", {
        paymentId: payment.id,
        invId: payment.external_id,
        paidAmount,
        expectedAmount: payment.amount,
      });
      return json(cors, 409, { error: "Сумма оплаты не совпадает" });
    }

    const { data: result, error: rpcError } = await supabase.rpc(
      "process_payment_completion",
      {
        p_payment_id: payment.id,
        p_expected_amount: paidAmount,
      }
    );

    if (rpcError) {
      console.error("Robokassa check RPC error:", rpcError);
      return json(cors, 500, { error: "Не удалось зачислить платёж" });
    }

    return json(cors, 200, {
      success: true,
      completed: true,
      amount: paidAmount,
      result,
      state,
    });
  } catch (error) {
    console.error("Robokassa check error:", error);
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
