import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// YooKassa configuration - ADD YOUR KEYS HERE
const YOOKASSA_SHOP_ID = Deno.env.get("YOOKASSA_SHOP_ID") || "";
const YOOKASSA_SECRET_KEY = Deno.env.get("YOOKASSA_SECRET_KEY") || "";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Необходима авторизация");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    
    if (authError || !user) {
      throw new Error("Неверный токен авторизации");
    }

    const { amount, description, return_url } = await req.json();

    if (!amount || amount < 1) {
      throw new Error("Сумма должна быть больше 0");
    }

    // Create payment record
    const { data: payment, error: paymentError } = await supabase
      .from("payments")
      .insert({
        user_id: user.id,
        amount: amount,
        currency: "RUB",
        status: "pending",
        payment_system: "yookassa",
        description: description || `Пополнение баланса на ${amount} ₽`,
      })
      .select()
      .single();

    if (paymentError) {
      throw new Error("Ошибка создания платежа: " + paymentError.message);
    }

    // Create YooKassa payment
    const idempotenceKey = crypto.randomUUID();
    
    const yooKassaPayment = {
      amount: {
        value: amount.toFixed(2),
        currency: "RUB",
      },
      capture: true,
      confirmation: {
        type: "redirect",
        return_url: return_url || `${req.headers.get("origin")}/profile?payment=success`,
      },
      description: description || `Пополнение баланса на ${amount} ₽`,
      metadata: {
        payment_id: payment.id,
        user_id: user.id,
      },
    };

    const response = await fetch("https://api.yookassa.ru/v3/payments", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Idempotence-Key": idempotenceKey,
        "Authorization": `Basic ${btoa(`${YOOKASSA_SHOP_ID}:${YOOKASSA_SECRET_KEY}`)}`,
      },
      body: JSON.stringify(yooKassaPayment),
    });

    if (!response.ok) {
      const error = await response.text();
      console.error("YooKassa API error:", error);
      throw new Error("Ошибка создания платежа в YooKassa");
    }

    const yooKassaResponse = await response.json();

    // Update payment with external ID
    await supabase
      .from("payments")
      .update({ 
        external_id: yooKassaResponse.id,
        metadata: yooKassaResponse,
      })
      .eq("id", payment.id);

    return new Response(
      JSON.stringify({
        success: true,
        payment_id: payment.id,
        payment_url: yooKassaResponse.confirmation.confirmation_url,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error: unknown) {
    console.error("YooKassa create error:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 400,
      }
    );
  }
});