import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const ROBOKASSA_PASSWORD2 = Deno.env.get("ROBOKASSA_PASSWORD2") || "";

async function createMD5(str: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(str);
  
  // Use crypto.subtle for MD5 - fail securely if not available
  const hashBuffer = await crypto.subtle.digest('MD5', data).catch((error) => {
    console.error("MD5 digest failed:", error);
    return null;
  });
  
  if (!hashBuffer) {
    // Fail securely - do not use weak fallback
    throw new Error("MD5 hashing is not supported in this environment. Cannot verify payment signature.");
  }
  
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Parse form data or query params
    let outSum: string, invId: string, signatureValue: string;

    if (req.method === "POST") {
      const formData = await req.formData().catch(() => null);
      if (formData) {
        outSum = formData.get("OutSum")?.toString() || "";
        invId = formData.get("InvId")?.toString() || "";
        signatureValue = formData.get("SignatureValue")?.toString() || "";
      } else {
        const body = await req.json();
        outSum = body.OutSum;
        invId = body.InvId;
        signatureValue = body.SignatureValue;
      }
    } else {
      const url = new URL(req.url);
      outSum = url.searchParams.get("OutSum") || "";
      invId = url.searchParams.get("InvId") || "";
      signatureValue = url.searchParams.get("SignatureValue") || "";
    }

    console.log("Robokassa callback:", { outSum, invId, signatureValue });

    // Verify signature: OutSum:InvId:Password2
    const expectedSignature = await createMD5(`${outSum}:${invId}:${ROBOKASSA_PASSWORD2}`);
    
    if (signatureValue.toLowerCase() !== expectedSignature.toLowerCase()) {
      console.error("Invalid signature", { expected: expectedSignature, received: signatureValue });
      return new Response("bad sign", { status: 400 });
    }

    // Find payment by external_id
    const { data: payment, error: findError } = await supabase
      .from("payments")
      .select("*")
      .eq("external_id", invId)
      .eq("payment_system", "robokassa")
      .single();

    if (findError || !payment) {
      console.error("Payment not found:", invId);
      return new Response("bad", { status: 404 });
    }

    // Update payment status
    const { error: updateError } = await supabase
      .from("payments")
      .update({ 
        status: "completed",
        updated_at: new Date().toISOString()
      })
      .eq("id", payment.id);

    if (updateError) {
      console.error("Error updating payment:", updateError);
      return new Response("bad", { status: 500 });
    }

    // Add balance to user profile
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("balance")
      .eq("user_id", payment.user_id)
      .single();

    if (!profileError && profile) {
      const newBalance = (profile.balance || 0) + payment.amount;
      await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", payment.user_id);

      // Log topup transaction
      await supabase.from("balance_transactions").insert({
        user_id: payment.user_id,
        amount: payment.amount,
        balance_after: newBalance,
        type: "topup",
        description: `Пополнение баланса (Робокасса)`,
        reference_id: payment.id,
        reference_type: "payment",
      });
    }

    console.log("Payment completed:", payment.id);

    // Return OK for Robokassa
    return new Response(`OK${invId}`, {
      headers: { "Content-Type": "text/plain" },
      status: 200,
    });
  } catch (error) {
    console.error("Robokassa callback error:", error);
    return new Response("bad", { status: 500 });
  }
});