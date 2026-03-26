/**
 * C4: AI-чатбот поддержки — первая линия ответов
 * Генерирует автоответ на новый тикет. При auto_reply — постит в ticket_messages.
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};


const FAQ_CONTEXT = `
FAQ AIMUZA (используй при ответе):
- Генерация: Suno V5 по умолчанию, Boost Style — V4.5. Лимит стиля 1000 символов для V5.
- Оплата: Robokassa, ЮKassa. Баланс пополняется автоматически после оплаты.
- Аккаунт: сброс пароля через email, верификация — в настройках профиля.
- Ошибки: опиши шаги воспроизведения, браузер, устройство.
`;

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Authorization required" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!
    );
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser(token);
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();
    const { ticket_id } = body;
    if (!ticket_id) {
      return new Response(
        JSON.stringify({ error: "ticket_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: chatbotSetting } = await supabaseAdmin
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "support_chatbot")
      .maybeSingle();

    const config = chatbotSetting?.value as {
      enabled?: boolean;
      auto_reply?: boolean;
      max_auto_replies?: number;
      bot_user_id?: string;
    } | null;

    if (!config?.enabled) {
      return new Response(
        JSON.stringify({ error: "support_chatbot not enabled" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const maxAutoReplies = config.max_auto_replies ?? 2;

    const { data: ticket, error: ticketError } = await supabaseAdmin
      .from("support_tickets")
      .select("id, user_id, subject, status")
      .eq("id", ticket_id)
      .single();

    if (ticketError || !ticket) {
      return new Response(
        JSON.stringify({ error: "Ticket not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (ticket.user_id !== user.id) {
      return new Response(
        JSON.stringify({ error: "Not your ticket" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: messages } = await supabaseAdmin
      .from("ticket_messages")
      .select("message, is_staff_reply")
      .eq("ticket_id", ticket_id)
      .order("created_at", { ascending: true });

    const staffRepliesCount = messages?.filter((m) => m.is_staff_reply).length ?? 0;
    if (staffRepliesCount >= maxAutoReplies) {
      return new Response(
        JSON.stringify({ reply: null, auto_posted: false, reason: "max_auto_replies_reached" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      return new Response(
        JSON.stringify({ error: "TIMEWEB_AGENT_TOKEN not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const threadText = (messages || [])
      .map((m) => `${m.is_staff_reply ? "Поддержка" : "Пользователь"}: ${m.message}`)
      .join("\n\n")
      .substring(0, 2000);

    const systemPrompt = `Ты AI-чатбот первой линии поддержки музыкальной платформы AIMUZA.
Сгенерируй краткий профессиональный ответ на обращение пользователя.
Правила: вежливо, по делу, на русском. Без приветствий в начале — только суть.
Если вопрос из FAQ — ответь по FAQ. Если нужна доп. информация — спроси конкретно.
Максимум 3-4 предложения. В конце можно добавить: "Если нужна помощь — напишите, передадим оператору."
${FAQ_CONTEXT}`;

    const userPrompt = `Тема: ${ticket.subject}\n\nПереписка:\n${threadText}\n\nСгенерируй ответ первой линии:`;

    const agentId = Deno.env.get("TIMEWEB_AGENT_ID") || "";
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${agentId}/v1/chat/completions`;
    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
      },
      body: JSON.stringify({
        model: "qwen3.5-flash",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: 0.5,
        max_tokens: 400,
      }),
    });

    if (!response.ok) {
      console.warn("[support-chatbot] DeepSeek error:", response.status);
      return new Response(
        JSON.stringify({ error: "AI service unavailable" }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const data = await response.json();
    const reply = data.choices?.[0]?.message?.content?.trim() || "";

    let autoPosted = false;

    if (config.auto_reply && reply) {
      let botUserId = config.bot_user_id;
      if (!botUserId) {
        const { data: settingsRow } = await supabaseAdmin
          .from("settings")
          .select("value")
          .eq("key", "super_admin_id")
          .maybeSingle();
        const raw = settingsRow?.value as string | null;
        botUserId = raw && raw.trim() ? raw : null;
      }

      if (botUserId) {
        const { error: insertError } = await supabaseAdmin.from("ticket_messages").insert({
          ticket_id,
          user_id: botUserId,
          message: reply,
          is_staff_reply: true,
        });

        if (!insertError) {
          autoPosted = true;
          await supabaseAdmin
            .from("support_tickets")
            .update({
              status: "in_progress",
              updated_at: new Date().toISOString(),
              assigned_to: botUserId,
            })
            .eq("id", ticket_id)
            .in("status", ["open", "waiting_response"]);
        } else {
          console.warn("[support-chatbot] Failed to insert:", insertError);
        }
      }
    }

    return new Response(
      JSON.stringify({ reply, auto_posted: autoPosted }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[support-chatbot] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
