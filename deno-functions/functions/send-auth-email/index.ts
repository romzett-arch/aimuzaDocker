
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import nodemailer from "npm:nodemailer@6.9.10";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const APP_NAME = "AI Planet Sound";
const APP_URL = "https://aiplanetsound.lovable.app";

function generateCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no O/0/1/I confusion
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

function getEmailHtml(type: string, data: { code?: string; link?: string; email: string; username?: string }) {
  const baseStyle = `
    font-family: 'Segoe UI', Arial, sans-serif;
    max-width: 600px;
    margin: 0 auto;
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
    border-radius: 16px;
    overflow: hidden;
    color: #e0e0e0;
  `;
  const buttonStyle = `
    display: inline-block;
    padding: 14px 32px;
    background: linear-gradient(135deg, #8b5cf6, #6366f1);
    color: #ffffff;
    text-decoration: none;
    border-radius: 12px;
    font-weight: 600;
    font-size: 16px;
  `;
  const codeStyle = `
    display: inline-block;
    padding: 16px 32px;
    background: rgba(139, 92, 246, 0.2);
    border: 2px solid #8b5cf6;
    border-radius: 12px;
    font-size: 32px;
    font-weight: 700;
    letter-spacing: 8px;
    color: #a78bfa;
    font-family: monospace;
  `;
  const headerHtml = `
    <div style="padding: 32px 24px 16px; text-align: center;">
      <h1 style="color: #a78bfa; font-size: 24px; margin: 0;">🎵 ${APP_NAME}</h1>
    </div>
  `;
  const footerHtml = `
    <div style="padding: 16px 24px 24px; text-align: center; font-size: 12px; color: #666;">
      <p>Это автоматическое письмо от ${APP_NAME}.</p>
      <p>Если вы не совершали это действие, проигнорируйте это письмо.</p>
    </div>
  `;

  if (type === "confirm") {
    return {
      subject: `${data.code} — код подтверждения ${APP_NAME}`,
      html: `
        <div style="${baseStyle}">
          ${headerHtml}
          <div style="padding: 16px 24px 32px;">
            <h2 style="color: #e0e0e0; text-align: center;">Подтвердите регистрацию ✉️</h2>
            <p style="text-align: center; line-height: 1.6;">
              Привет, ${data.username || "музыкант"}! Введите код ниже на странице регистрации:
            </p>
            <div style="text-align: center; margin: 24px 0;">
              <span style="${codeStyle}">${data.code}</span>
            </div>
            <p style="text-align: center; font-size: 13px; color: #999;">
              Код действителен 15 минут. Если вы не регистрировались — проигнорируйте это письмо.
            </p>
          </div>
          ${footerHtml}
        </div>
      `,
    };
  }

  if (type === "welcome") {
    return {
      subject: `Добро пожаловать в ${APP_NAME}! 🎵`,
      html: `
        <div style="${baseStyle}">
          ${headerHtml}
          <div style="padding: 16px 24px 32px;">
            <h2 style="color: #e0e0e0; text-align: center;">Привет, ${data.username || "музыкант"}! 👋</h2>
            <p style="text-align: center; line-height: 1.6;">
              Добро пожаловать на платформу AI Planet Sound — хаб AI музыкантов!
            </p>
            <div style="text-align: center; margin: 24px 0;">
              <a href="${APP_URL}" style="${buttonStyle}">Начать создавать 🚀</a>
            </div>
            <p style="text-align: center; font-size: 14px; color: #999;">
              Ваш аккаунт: <strong>${data.email}</strong>
            </p>
          </div>
          ${footerHtml}
        </div>
      `,
    };
  }

  // reset
  return {
    subject: `Сброс пароля — ${APP_NAME}`,
    html: `
      <div style="${baseStyle}">
        ${headerHtml}
        <div style="padding: 16px 24px 32px;">
          <h2 style="color: #e0e0e0; text-align: center;">Сброс пароля 🔑</h2>
          <p style="text-align: center; line-height: 1.6;">
            Вы запросили сброс пароля для аккаунта <strong>${data.email}</strong>.
          </p>
          <div style="text-align: center; margin: 24px 0;">
            <a href="${data.link}" style="${buttonStyle}">Сбросить пароль</a>
          </div>
          <p style="text-align: center; font-size: 13px; color: #999;">
            Ссылка действительна 1 час.
          </p>
        </div>
        ${footerHtml}
      </div>
    `,
  };
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
    const { email, type, username } = await req.json();

    if (!email || !type) {
      return new Response(
        JSON.stringify({ error: "email and type are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    let link: string | undefined;
    let code: string | undefined;

    if (type === "confirm") {
      // Generate 6-char code and store in DB
      code = generateCode();
      
      // Clean up old codes for this email
      await adminClient.from("email_verifications").delete().eq("email", email);
      
      // Insert new code
      const { error: insertError } = await adminClient.from("email_verifications").insert({
        email,
        code,
        username: username || null,
      });
      
      if (insertError) {
        console.error("Insert verification code error:", insertError);
        return new Response(
          JSON.stringify({ error: "Failed to create verification code" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (type === "reset") {
      const { data, error } = await adminClient.auth.admin.generateLink({
        type: "recovery",
        email,
        options: { redirectTo: `${APP_URL}/auth?mode=reset` },
      });
      if (error) {
        console.error("Generate reset link error:", error);
        return new Response(
          JSON.stringify({ error: "Failed to generate reset link" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      link = data.properties?.action_link;
    }

    const template = getEmailHtml(type, { username, link, email, code });
    await sendEmail(email, template.subject, template.html);

    console.log(`[send-auth-email] Sent ${type} email to ${email}`);

    return new Response(
      JSON.stringify({ success: true }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("[send-auth-email] Error:", error);
    const message = error instanceof Error ? error.message : "Internal server error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
