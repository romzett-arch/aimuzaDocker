import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Helper function to verify YooKassa webhook signature
async function verifyWebhookSignature(
  body: string,
  signature: string | null,
  secretKey: string
): Promise<boolean> {
  if (!signature) {
    return false;
  }

  // YooKassa uses HMAC-SHA256 for webhook signatures
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secretKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signatureBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(body)
  );

  // Convert to hex string
  const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  // Constant-time comparison to prevent timing attacks
  if (signature.length !== expectedSignature.length) {
    return false;
  }

  let result = 0;
  for (let i = 0; i < signature.length; i++) {
    result |= signature.charCodeAt(i) ^ expectedSignature.charCodeAt(i);
  }

  return result === 0;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const yookassaSecretKey = Deno.env.get("YOOKASSA_SECRET_KEY");

    // Get the raw body for signature verification
    const rawBody = await req.text();
    
    // Verify webhook signature - REQUIRED for security
    if (!yookassaSecretKey) {
      console.error("YOOKASSA_SECRET_KEY not configured - rejecting webhook request for security");
      return new Response(
        JSON.stringify({ error: "Webhook secret not configured" }),
        { 
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 500 
        }
      );
    }

    const signature = req.headers.get("X-YooKassa-Signature") || 
                      req.headers.get("x-yookassa-signature");
    
    const isValid = await verifyWebhookSignature(rawBody, signature, yookassaSecretKey);
    
    if (!isValid) {
      console.error("YooKassa webhook signature verification failed");
      return new Response(
        JSON.stringify({ error: "Invalid webhook signature" }),
        { 
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 401 
        }
      );
    }
    
    console.log("YooKassa webhook signature verified successfully");

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const body = JSON.parse(rawBody);
    console.log("YooKassa webhook received:", JSON.stringify(body, null, 2));

    const { event, object } = body;

    if (!object || !object.id) {
      throw new Error("Invalid webhook payload");
    }

    // Find payment by external_id (YooKassa payment ID)
    const { data: payment, error: findError } = await supabase
      .from("payments")
      .select("*")
      .eq("external_id", object.id)
      .eq("payment_system", "yookassa")
      .single();

    if (findError || !payment) {
      console.error("Payment not found:", object.id);
      return new Response(
        JSON.stringify({ error: "Payment not found" }),
        { 
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 404 
        }
      );
    }

    let newStatus = payment.status;

    // Handle different YooKassa events
    switch (event) {
      case "payment.succeeded":
        newStatus = "completed";
        break;
      case "payment.canceled":
        newStatus = "cancelled";
        break;
      case "payment.waiting_for_capture":
        newStatus = "pending";
        break;
      case "refund.succeeded":
        newStatus = "refunded";
        break;
      default:
        console.log("Unhandled event type:", event);
    }

    // Update payment status
    const { error: updateError } = await supabase
      .from("payments")
      .update({ 
        status: newStatus,
        metadata: object,
        updated_at: new Date().toISOString()
      })
      .eq("id", payment.id);

    if (updateError) {
      console.error("Error updating payment:", updateError);
      throw new Error("Failed to update payment");
    }

    // Add balance to user profile if payment succeeded
    if (event === "payment.succeeded" && payment.status !== "completed") {
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
          description: `Пополнение баланса (ЮKassa)`,
          reference_id: payment.id,
          reference_type: "payment",
        });
        
        console.log(`Balance updated for user ${payment.user_id}: ${newBalance}`);
      }
    }

    console.log("Payment updated:", payment.id, "Status:", newStatus);

    return new Response(
      JSON.stringify({ success: true }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error: unknown) {
    console.error("YooKassa callback error:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});
