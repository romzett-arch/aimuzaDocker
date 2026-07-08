import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ROBOKASSA_PASSWORD2 = Deno.env.get("ROBOKASSA_PASSWORD2") || "";

const ROBOKASSA_ALLOWED_IPS = ["185.59.216.65", "185.59.217.65"];

function getClientIP(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  const realIp = req.headers.get("x-real-ip");
  if (realIp) return realIp.trim();
  return "unknown";
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

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  try {
    // --- IP-фильтрация (мягкая: логируем, но не блокируем — подпись основная защита) ---
    const clientIP = getClientIP(req);
    const isTest = Deno.env.get("ROBOKASSA_TEST_MODE") === "true";
    const ipTrusted = isTest || ROBOKASSA_ALLOWED_IPS.some((ip) => clientIP.startsWith(ip));
    if (!ipTrusted) {
      console.warn("Robokassa callback from unexpected IP:", clientIP);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // --- Парсинг параметров (POST form-data, POST JSON, GET query) ---
    let outSum = "";
    let invId = "";
    let signatureValue = "";

    if (req.method === "POST") {
      const contentType = req.headers.get("content-type") || "";

      if (contentType.includes("application/x-www-form-urlencoded")) {
        const formText = await req.text();
        const params = new URLSearchParams(formText);
        outSum = params.get("OutSum") || "";
        invId = params.get("InvId") || "";
        signatureValue = params.get("SignatureValue") || "";
      } else if (contentType.includes("multipart/form-data")) {
        const formData = await req.formData();
        outSum = formData.get("OutSum")?.toString() || "";
        invId = formData.get("InvId")?.toString() || "";
        signatureValue = formData.get("SignatureValue")?.toString() || "";
      } else {
        const body = await req.json();
        outSum = String(body.OutSum || "");
        invId = String(body.InvId || "");
        signatureValue = String(body.SignatureValue || "");
      }
    } else {
      const url = new URL(req.url);
      outSum = url.searchParams.get("OutSum") || "";
      invId = url.searchParams.get("InvId") || "";
      signatureValue = url.searchParams.get("SignatureValue") || "";
    }

    console.log("Robokassa callback:", { outSum, invId, clientIP });

    if (!outSum || !invId || !signatureValue) {
      await logCallback(supabase, { invId, outSum, signatureValid: false, clientIP, result: "bad params" });
      return new Response("bad params", { status: 400 });
    }

    // --- Проверка подписи: MD5(OutSum:InvId:Password2) ---
    if (!ROBOKASSA_PASSWORD2) {
      console.error("ROBOKASSA_PASSWORD2 not configured");
      return new Response("bad config", { status: 500 });
    }

    const expectedSignature = await computeMD5(
      `${outSum}:${invId}:${ROBOKASSA_PASSWORD2}`
    );

    if (signatureValue.toLowerCase() !== expectedSignature.toLowerCase()) {
      console.error("Invalid signature", {
        expected: expectedSignature,
        received: signatureValue,
      });
      await logCallback(supabase, { invId, outSum, signatureValid: false, clientIP, result: "bad sign" });
      return new Response("bad sign", { status: 400 });
    }

    // --- Найти платёж ---
    const { data: payment, error: findError } = await supabase
      .from("payments")
      .select("*")
      .eq("external_id", invId)
      .eq("payment_system", "robokassa")
      .single();

    if (findError || !payment) {
      console.error("Payment not found:", invId);
      return new Response("bad id", { status: 404 });
    }

    // --- Кросс-валидация суммы ---
    const paidAmount = Math.round(Number(outSum));
    if (paidAmount !== payment.amount) {
      console.error("Amount mismatch!", {
        paid: paidAmount,
        expected: payment.amount,
      });
      return new Response("bad amount", { status: 400 });
    }

    // --- Атомарное зачисление через SQL-функцию ---
    const { data: result, error: rpcError } = await supabase.rpc(
      "process_payment_completion",
      {
        p_payment_id: payment.id,
        p_expected_amount: paidAmount,
      }
    );

    if (rpcError) {
      console.error("RPC error:", rpcError);
      return new Response("bad", { status: 500 });
    }

    const res = result as {
      success: boolean;
      already_processed?: boolean;
      error?: string;
    };

    if (!res.success) {
      console.error("process_payment_completion failed:", res.error);
      // Если уже обработан — OK для Робокассы
      return new Response("bad", { status: 500 });
    }

    if (res.already_processed) {
      console.log("Payment already processed (idempotent):", payment.id);
    } else {
      console.log("Payment completed:", payment.id, "Amount:", payment.amount);
    }

    await logCallback(supabase, {
      invId,
      outSum,
      signatureValid: true,
      clientIP,
      result: res.already_processed ? "ok_idempotent" : "ok",
    });

    // Робокасса ожидает формат OK{InvId}
    return new Response(`OK${invId}`, {
      status: 200,
      headers: { "Content-Type": "text/plain" },
    });
  } catch (error) {
    console.error("Robokassa callback error:", error);
    return new Response("bad", { status: 500 });
  }
});

interface CallbackLog {
  invId: string;
  outSum: string;
  signatureValid: boolean;
  clientIP: string;
  result: string;
}

async function logCallback(
  supabase: ReturnType<typeof createClient>,
  log: CallbackLog
) {
  try {
    await supabase.from("payment_callbacks").insert({
      payment_system: "robokassa",
      inv_id: log.invId,
      out_sum: log.outSum,
      signature_valid: log.signatureValid,
      client_ip: log.clientIP,
      result: log.result,
    });
  } catch (e) {
    console.error("Failed to log callback:", e);
  }
}
