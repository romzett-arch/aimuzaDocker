import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import nodemailer from "npm:nodemailer@6.9.10";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const APP_NAME = "AI Planet Sound";
const APP_URL = "https://aiplanetsound.lovable.app";

function wrapInTemplate(bodyHtml: string, senderType: string, unsubscribeUrl?: string) {
  const senderLabel = senderType === "personal" ? "Личное сообщение от администратора" : APP_NAME;

  return `
    <div style="font-family: 'Segoe UI', Arial, sans-serif; max-width: 600px; margin: 0 auto; background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%); border-radius: 16px; overflow: hidden; color: #e0e0e0;">
      <div style="padding: 32px 24px 16px; text-align: center;">
        <h1 style="color: #a78bfa; font-size: 24px; margin: 0;">🎵 ${APP_NAME}</h1>
        <p style="font-size: 12px; color: #888; margin-top: 4px;">${senderLabel}</p>
      </div>
      <div style="padding: 16px 24px 32px;">
        ${bodyHtml}
      </div>
      <div style="padding: 16px 24px 24px; text-align: center; font-size: 12px; color: #666; border-top: 1px solid rgba(255,255,255,0.05);">
        <p>Это письмо от ${APP_NAME}.</p>
        ${unsubscribeUrl ? `<p><a href="${unsubscribeUrl}" style="color: #888; text-decoration: underline;">Отписаться от рассылки</a></p>` : ""}
      </div>
    </div>
  `;
}

async function sendEmail(to: string, subject: string, html: string) {
  const transporter = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST"),
    port: parseInt(Deno.env.get("SMTP_PORT") || "465"),
    secure: true,
    auth: {
      user: Deno.env.get("SMTP_USER"),
      pass: Deno.env.get("SMTP_PASS"),
    },
  });
  await transporter.sendMail({
    from: `"${APP_NAME}" <${Deno.env.get("SMTP_USER")}>`,
    to,
    subject,
    html,
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Verify admin
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

    // Verify the caller is admin
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Check admin role
    const { data: roleCheck } = await adminClient.rpc("has_role", {
      _user_id: user.id,
      _role: "admin",
    });
    const { data: superCheck } = await adminClient.rpc("has_role", {
      _user_id: user.id,
      _role: "super_admin",
    });
    if (!roleCheck && !superCheck) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { action } = body;

    // ---- SEND EMAIL ----
    if (action === "send") {
      const { recipients, subject, body_html, sender_type, template_id } = body;
      // recipients: array of { user_id, email }

      if (!recipients?.length || !subject || !body_html) {
        return new Response(JSON.stringify({ error: "Missing fields" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      let sent = 0;
      let failed = 0;
      const errors: string[] = [];

      for (const r of recipients) {
        try {
          const unsubscribeUrl = `${APP_URL}/unsubscribe?uid=${r.user_id}`;
          const html = wrapInTemplate(body_html, sender_type || "project", unsubscribeUrl);
          await sendEmail(r.email, subject, html);

          await adminClient.from("admin_emails").insert({
            sender_id: user.id,
            sender_type: sender_type || "project",
            recipient_id: r.user_id || null,
            recipient_email: r.email,
            subject,
            body_html,
            template_id: template_id || null,
            status: "sent",
          });
          sent++;
        } catch (err: any) {
          failed++;
          errors.push(`${r.email}: ${err.message}`);
          await adminClient.from("admin_emails").insert({
            sender_id: user.id,
            sender_type: sender_type || "project",
            recipient_id: r.user_id || null,
            recipient_email: r.email,
            subject,
            body_html,
            template_id: template_id || null,
            status: "failed",
            error_message: err.message,
          });
        }
      }

      console.log(`[send-admin-email] Sent: ${sent}, Failed: ${failed}`);

      return new Response(
        JSON.stringify({ success: true, sent, failed, errors }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ---- UNSUBSCRIBE ----
    if (action === "unsubscribe") {
      const { user_id } = body;
      if (!user_id) {
        return new Response(JSON.stringify({ error: "user_id required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      await adminClient.from("profiles").update({ email_unsubscribed: true }).eq("user_id", user_id);

      return new Response(
        JSON.stringify({ success: true }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(JSON.stringify({ error: "Unknown action" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error: unknown) {
    console.error("[send-admin-email] Error:", error);
    const message = error instanceof Error ? error.message : "Internal server error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
