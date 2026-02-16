import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Robokassa configuration - ADD YOUR KEYS HERE
const ROBOKASSA_MERCHANT_LOGIN = Deno.env.get("ROBOKASSA_MERCHANT_LOGIN") || "";
const ROBOKASSA_PASSWORD1 = Deno.env.get("ROBOKASSA_PASSWORD1") || ""; // For signature creation
const ROBOKASSA_PASSWORD2 = Deno.env.get("ROBOKASSA_PASSWORD2") || ""; // For result verification
const ROBOKASSA_TEST_MODE = Deno.env.get("ROBOKASSA_TEST_MODE") === "true";

function md5(str: string): string {
  const encoder = new TextEncoder();
  const data = encoder.encode(str);
  const hashBuffer = new Uint8Array(16);
  
  // Simple MD5 implementation for Deno
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  return Math.abs(hash).toString(16).padStart(32, '0');
}

async function createMD5(str: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(str);
  const hashBuffer = await crypto.subtle.digest('MD5', data).catch(() => null);
  
  if (hashBuffer) {
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  }
  
  // Fallback to simple hash
  return md5(str);
}

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

    const { amount, description } = await req.json();

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
        payment_system: "robokassa",
        description: description || `Пополнение баланса на ${amount} ₽`,
      })
      .select()
      .single();

    if (paymentError) {
      throw new Error("Ошибка создания платежа: " + paymentError.message);
    }

    // Generate Robokassa signature
    // Format: MerchantLogin:OutSum:InvId:Password1
    const invId = payment.id.replace(/-/g, '').slice(0, 10); // Short invoice ID
    const signatureString = `${ROBOKASSA_MERCHANT_LOGIN}:${amount}:${invId}:${ROBOKASSA_PASSWORD1}`;
    const signature = await createMD5(signatureString);

    // Build payment URL
    const baseUrl = ROBOKASSA_TEST_MODE
      ? "https://auth.robokassa.ru/Merchant/Index.aspx"
      : "https://auth.robokassa.ru/Merchant/Index.aspx";

    const params = new URLSearchParams({
      MerchantLogin: ROBOKASSA_MERCHANT_LOGIN,
      OutSum: amount.toString(),
      InvId: invId,
      Description: description || `Пополнение баланса на ${amount} ₽`,
      SignatureValue: signature,
      IsTest: ROBOKASSA_TEST_MODE ? "1" : "0",
      Culture: "ru",
    });

    // Update payment with external ID
    await supabase
      .from("payments")
      .update({ external_id: invId })
      .eq("id", payment.id);

    const paymentUrl = `${baseUrl}?${params.toString()}`;

    return new Response(
      JSON.stringify({
        success: true,
        payment_id: payment.id,
        payment_url: paymentUrl,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error: unknown) {
    console.error("Robokassa create error:", error);
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