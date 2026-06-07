import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

async function sha256(message: string): Promise<string> {
  const msgBuffer = new TextEncoder().encode(message);
  const hashBuffer = await crypto.subtle.digest("SHA-256", msgBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "");
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const adminClient = createClient(supabaseUrl, supabaseServiceKey);

    const { data: claims, error: claimsError } = await userClient.auth.getClaims(token);
    if (claimsError || !claims?.claims?.sub) {
      return new Response(JSON.stringify({ error: "Invalid token" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const adminUserId = claims.claims.sub as string;

    const { data: userRole } = await adminClient
      .from("user_roles")
      .select("role")
      .eq("user_id", adminUserId)
      .single();

    if (!userRole || userRole.role !== "super_admin") {
      return new Response(JSON.stringify({ error: "Доступ запрещен. Только для super_admin." }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { pin, target_user_id, new_password } = body;

    if (!pin || typeof pin !== "string" || pin.length !== 6) {
      return new Response(JSON.stringify({ error: "Требуется 6-значный PIN-код" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!target_user_id || typeof target_user_id !== "string") {
      return new Response(JSON.stringify({ error: "target_user_id обязателен" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!new_password || typeof new_password !== "string" || new_password.length < 6) {
      return new Response(JSON.stringify({ error: "Новый пароль должен быть не короче 6 символов" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: pinSetting } = await adminClient
      .from("settings")
      .select("value")
      .eq("key", "backup_pin_hash")
      .single();

    if (!pinSetting?.value) {
      return new Response(JSON.stringify({ error: "PIN-код не настроен" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const pinHash = await sha256(pin);
    if (pinHash !== pinSetting.value) {
      await adminClient.from("impersonation_action_logs").insert({
        admin_user_id: adminUserId,
        target_user_id,
        action_type: "admin_password_change_pin_failed",
        action_payload: {},
        result_status: "error",
        error_message: "Invalid PIN",
      });

      return new Response(JSON.stringify({ error: "Неверный PIN-код" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: targetUser, error: targetError } = await adminClient.auth.admin.getUserById(target_user_id);
    if (targetError || !targetUser?.user) {
      return new Response(JSON.stringify({ error: "Целевой пользователь не найден" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { error: updateError } = await adminClient.auth.admin.updateUserById(target_user_id, {
      password: new_password,
    });

    const logEntry = {
      admin_user_id: adminUserId,
      target_user_id,
      action_type: "admin_password_changed",
      action_payload: {
        email: targetUser.user.email ?? null,
        password_length: new_password.length,
      },
      result_status: updateError ? "error" : "success",
      error_message: updateError ? updateError.message : null,
    };

    await adminClient.from("impersonation_action_logs").insert(logEntry);

    if (updateError) {
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true, target_user_id }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
