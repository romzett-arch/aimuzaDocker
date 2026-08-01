import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Verify caller is admin
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const anonClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!);
    const { data: { user: caller }, error: authError } = await anonClient.auth.getUser(
      authHeader.replace("Bearer ", "")
    );

    if (authError || !caller) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { userId } = await req.json();
    if (!userId) {
      return new Response(JSON.stringify({ error: "userId is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Admins can delete other users; a user can delete only their own account.
    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { data: roleData, error: roleError } = await adminClient
      .from("user_roles")
      .select("role")
      .eq("user_id", caller.id);

    if (roleError) {
      return new Response(JSON.stringify({ error: "Failed to verify caller role" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const isSelfDelete = userId === caller.id;
    const isAdmin = (roleData || []).some(({ role }) => ["admin", "super_admin"].includes(role));
    if (!isSelfDelete && !isAdmin) {
      return new Response(JSON.stringify({ error: "Forbidden: admin role required" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Protect super_admin from deletion
    const [{ data: targetRoles, error: targetRoleError }, { data: targetProfile, error: targetProfileError }] = await Promise.all([
      adminClient
      .from("user_roles")
      .select("role")
      .eq("user_id", userId),
      adminClient
        .from("profiles")
        .select("is_protected")
        .eq("user_id", userId)
        .maybeSingle(),
    ]);

    if (targetRoleError || targetProfileError) {
      return new Response(JSON.stringify({ error: "Failed to verify target protection" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if ((targetRoles || []).some(({ role }) => role === "super_admin") || targetProfile?.is_protected) {
      return new Response(JSON.stringify({ error: "Cannot delete super_admin" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Delete from auth.users (CASCADE will handle related data)
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(userId);

    if (deleteError) {
      await adminClient.from("impersonation_action_logs").insert({
        admin_user_id: caller.id,
        target_user_id: userId,
        action_type: "admin_user_delete",
        action_payload: {},
        result_status: "error",
        error_message: deleteError.message,
      });
      console.error("Delete user error:", deleteError);
      return new Response(JSON.stringify({ error: deleteError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    await adminClient.from("impersonation_action_logs").insert({
      admin_user_id: caller.id,
      target_user_id: userId,
      action_type: "admin_user_delete",
      action_payload: {},
      result_status: "success",
      error_message: null,
    });

    return new Response(
      JSON.stringify({ success: true, message: "User fully deleted" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("admin-delete-user error:", err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
