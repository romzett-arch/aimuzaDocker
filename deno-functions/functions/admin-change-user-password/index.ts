import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const MAX_PIN_FAILURES = 10;
const PIN_WINDOW_MS = 15 * 60 * 1000;
const PASSWORD_POLICY_MESSAGE =
  "Пароль должен содержать минимум 8 символов, заглавную букву, цифру и спецсимвол";

function isValidPassword(password: unknown): password is string {
  return typeof password === "string" &&
    password.length >= 8 &&
    /[A-ZА-ЯЁ]/.test(password) &&
    /[0-9]/.test(password) &&
    /[^A-Za-zА-Яа-яЁё0-9]/.test(password);
}

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

    const { data: userRole, error: roleError } = await adminClient
      .from("user_roles")
      .select("role")
      .eq("user_id", adminUserId)
      .eq("role", "super_admin")
      .maybeSingle();

    if (roleError || !userRole) {
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

    if (!isValidPassword(new_password)) {
      return new Response(JSON.stringify({ error: PASSWORD_POLICY_MESSAGE }), {
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

    const pinWindowStart = new Date(Date.now() - PIN_WINDOW_MS).toISOString();
    const { count: failedPinCount, error: failedPinCountError } = await adminClient
      .from("impersonation_action_logs")
      .select("id", { count: "exact", head: true })
      .eq("admin_user_id", adminUserId)
      .eq("action_type", "admin_password_change_pin_failed")
      .eq("result_status", "error")
      .gte("created_at", pinWindowStart);

    if (failedPinCountError) {
      console.error("Failed to check PIN attempt limit", failedPinCountError);
      return new Response(JSON.stringify({ error: "Не удалось проверить лимит PIN" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if ((failedPinCount ?? 0) >= MAX_PIN_FAILURES) {
      return new Response(JSON.stringify({
        error: "Лимит PIN исчерпан. Попробуйте через 15 минут",
        code: "PIN_ATTEMPTS_EXCEEDED",
      }), {
        status: 429,
        headers: { ...corsHeaders, "Content-Type": "application/json", "Retry-After": "900" },
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

    if (targetUser.user.email) {
      const { error: tokenDeleteError } = await adminClient
        .from("email_verifications")
        .delete()
        .eq("email", targetUser.user.email.toLowerCase())
        .like("code", "RESET:%");
      if (tokenDeleteError) {
        console.error("Failed to invalidate recovery tokens", tokenDeleteError);
      }

      const { error: notificationError } = await adminClient.functions.invoke("send-admin-email", {
        body: {
          to: targetUser.user.email,
          subject: "Пароль AIMUZA изменён администратором",
          html: "<p>Пароль вашего аккаунта AIMUZA был изменён администратором. Если вы не ожидали этого, немедленно обратитесь в поддержку.</p>",
        },
      });
      if (notificationError) {
        console.error("Failed to send password change notification", notificationError);
      }
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
