
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { email, code } = await req.json();

    if (!email || !code) {
      return new Response(
        JSON.stringify({ error: "email and code are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Find matching verification code
    const { data: verification, error: fetchError } = await adminClient
      .from("email_verifications")
      .select("*")
      .eq("email", email)
      .eq("code", code.toUpperCase().trim())
      .eq("verified", false)
      .gt("expires_at", new Date().toISOString())
      .order("created_at", { ascending: false })
      .limit(1)
      .single();

    if (fetchError || !verification) {
      return new Response(
        JSON.stringify({ error: "Неверный или просроченный код" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Mark as verified
    await adminClient
      .from("email_verifications")
      .update({ verified: true })
      .eq("id", verification.id);

    // Find the user by email and confirm them
    const { data: usersData } = await adminClient.auth.admin.listUsers();
    const user = usersData?.users?.find((u) => u.email === email);

    if (user) {
      // Confirm the user's email
      await adminClient.auth.admin.updateUserById(user.id, {
        email_confirm: true,
      });
    }

    // Clean up all codes for this email
    await adminClient.from("email_verifications").delete().eq("email", email);

    console.log(`[verify-email-code] Email verified: ${email}`);

    return new Response(
      JSON.stringify({ success: true }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("[verify-email-code] Error:", error);
    const message = error instanceof Error ? error.message : "Internal server error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
