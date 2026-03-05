import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { crypto as stdCrypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";

const ROBOKASSA_PASSWORD2 = Deno.env.get("ROBOKASSA_PASSWORD2") || "";

const ROBOKASSA_ALLOWED_IPS = ["185.59.216.65", "185.59.217.65"];

function getClientIP(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  const realIp = req.headers.get("x-real-ip");
  if (realIp) return realIp.trim();
  return "unknown";
}

async function computeMD5(str: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(str);
  const hashBuffer = await stdCrypto.subtle.digest("MD5", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  try {
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
    if (paidAmount !== Number(payment.amount)) {
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
      return new Response("bad", { status: 500 });
    }

    if (res.already_processed) {
      console.log("Payment already processed (idempotent):", payment.id);
    } else {
      console.log("Payment completed:", payment.id, "Amount:", payment.amount);
    }

    return new Response(`OK${invId}`, {
      status: 200,
      headers: { "Content-Type": "text/plain" },
    });
  } catch (error) {
    console.error("Robokassa callback error:", error);
    return new Response("bad", { status: 500 });
  }
});