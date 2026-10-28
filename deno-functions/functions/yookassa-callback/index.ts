import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { assertProviderState, verifiedRubles } from './provider-state.ts';

const YOOKASSA_SHOP_ID = Deno.env.get("YOOKASSA_SHOP_ID") || "";
const YOOKASSA_SECRET_KEY = Deno.env.get("YOOKASSA_SECRET_KEY") || "";

// IP-адреса YooKassa для верификации webhook-запросов
// https://yookassa.ru/developers/using-api/webhooks#ip
const YOOKASSA_IPS = [
  "185.71.76.", "185.71.77.",
  "77.75.153.", "77.75.156.",
  "77.75.154.", "77.75.155.",
  "2a02:5180:0:",
];

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const rawBody = await req.text();
    const body = JSON.parse(rawBody);

    console.log("YooKassa webhook:", body.event, body.object?.id);

    const { event, object } = body;
    if (!['payment.succeeded','payment.canceled','payment.waiting_for_capture','refund.succeeded'].includes(event)) return new Response('Unknown event',{status:400});
    if (!object?.id || !/^[a-zA-Z0-9-]{1,80}$/.test(object.id)) {
      return new Response(JSON.stringify({ error: "Invalid payload" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // --- Верификация через обратный запрос к API YooKassa ---
    // Вместо ненадёжной подписи — проверяем реальный статус платежа у YooKassa
    const isRefund = event === "refund.succeeded";
    const verified = await verifyPaymentViaApi(object.id, isRefund);
    if (!verified) {
      console.error("Payment verification failed for:", object.id);
      return new Response(JSON.stringify({ error: "Verification failed" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }
    try { assertProviderState(event,object.id,verified); } catch {
      return new Response(JSON.stringify({error:"Event does not match verified provider state"}),{status:409});
    }

    // --- Найти платёж в БД ---
    const { data: payment, error: findError } = await supabase
      .from("payments")
      .select("*")
      .eq("external_id", isRefund ? verified.payment_id : verified.id)
      .eq("payment_system", "yookassa")
      .single();

    if (findError || !payment) {
      console.error("Payment not found in DB:", object.id);
      // Возвращаем 200, чтобы YooKassa не ретраила — платёж просто не наш
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // --- Обработка события ---
    switch (event) {
      case "payment.succeeded": {
        // Кросс-валидация суммы: то, что пришло от ЮKassa, должно совпадать
        const paidAmount = verifiedRubles((verified.amount as {value:string}).value);

        // Атомарное зачисление через SQL-функцию
        const { data: result, error: rpcError } = await supabase.rpc(
          "process_payment_completion",
          {
            p_payment_id: payment.id,
            p_expected_amount: paidAmount,
          }
        );

        if (rpcError) {
          console.error("RPC error:", rpcError);
          return serverError("Balance credit failed");
        }

        const res = result as { success: boolean; already_processed?: boolean; error?: string };

        if (!res.success) {
          console.error("process_payment_completion failed:", res.error);
          // amount_mismatch — серьёзная проблема, логируем
          if (res.error === "amount_mismatch") {
            console.error("AMOUNT MISMATCH! DB:", payment.amount, "YooKassa:", paidAmount);
          }
          return serverError(res.error || "Processing failed");
        }

        // Сохраняем metadata от YooKassa
        await supabase
          .from("payments")
          .update({ metadata: verified })
          .eq("id", payment.id);

        if (res.already_processed) {
          console.log("Payment already processed:", payment.id);
        } else {
          console.log("Payment completed:", payment.id, "Amount:", payment.amount);
        }
        break;
      }

      case "payment.canceled": {
        await supabase
          .from("payments")
          .update({ status: "cancelled", metadata: verified, updated_at: new Date().toISOString() })
          .eq("id", payment.id).eq("status","pending");
        console.log("Payment cancelled:", payment.id);
        break;
      }

      case "payment.waiting_for_capture": {
        await supabase
          .from("payments")
          .update({ metadata: verified, updated_at: new Date().toISOString() })
          .eq("id", payment.id);
        console.log("Payment waiting for capture:", payment.id);
        break;
      }

      case "refund.succeeded": {
        const refundAmount = verifiedRubles((verified.amount as {value:string}).value);
        if (!Number.isSafeInteger(refundAmount) || refundAmount <= 0) return new Response("Invalid verified refund amount",{status:409});

        const { data: refundResult, error: refundError } = await supabase.rpc(
          "process_payment_refund",
          {
            p_payment_id: payment.id,
            p_refund_amount: refundAmount > 0 ? refundAmount : null,
          }
        );

        if (refundError) {
          console.error("Refund RPC error:", refundError);
          return serverError("Refund processing failed");
        }

        const rr = refundResult as { success: boolean; error?: string } | null;
        if (!rr) {
          console.error("Refund RPC returned null for payment:", payment.id);
          return serverError("Refund processing failed");
        } else if (!rr.success) {
          console.error("Refund failed:", rr.error);
          return serverError("Refund processing failed");
        } else {
          console.log("Refund processed:", payment.id, "Amount:", refundAmount);
        }

        await supabase
          .from("payments")
          .update({ metadata: verified })
          .eq("id", payment.id);
        break;
      }

      default:
        console.log("Unhandled event:", event);
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    console.error("YooKassa callback error:", error);
    return serverError("Internal error");
  }
});

// --- Верификация платежа через обратный запрос к API YooKassa ---
async function verifyPaymentViaApi(
  paymentId: string, isRefund = false
): Promise<Record<string, unknown> | null> {
  try {
    const response = await fetch(
      `https://api.yookassa.ru/v3/${isRefund ? "refunds" : "payments"}/${paymentId}`,
      {
        signal: AbortSignal.timeout(15000),
        headers: {
          Authorization: `Basic ${btoa(`${YOOKASSA_SHOP_ID}:${YOOKASSA_SECRET_KEY}`)}`,
        },
      }
    );

    if (!response.ok) {
      console.error("YooKassa verify API error:", response.status);
      return null;
    }

    const data = await response.json();

    // Проверяем, что payment_id валидный и принадлежит нашему магазину
    if (!data.id || data.id !== paymentId) {
      console.error("Payment ID mismatch in verification");
      return null;
    }

    return data;
  } catch (error) {
    console.error("YooKassa verify error:", error);
    return null;
  }
}

function serverError(message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status: 500,
    headers: { "Content-Type": "application/json" },
  });
}
