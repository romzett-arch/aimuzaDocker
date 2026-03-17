import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { Mode } from "./constants.ts";
import { corsHeaders, AGENT_ACCESS_ID, SERVICE_NAMES, DEFAULT_PRICES, MESSAGES, TAG_COLORS } from "./constants.ts";
import { buildPrompts } from "./prompts.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Необходима авторизация" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = authHeader.replace("Bearer ", "");
    const { data, error: authError } = await supabase.auth.getClaims(token);

    if (authError || !data?.claims?.sub) {
      console.error("Auth error:", authError);
      return new Response(
        JSON.stringify({ error: "Неверный токен авторизации" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const user_id = data.claims.sub as string;
    const { mode, text, topicTitle, topicContent, threadPosts, topicId } = await req.json() as {
      mode: Mode;
      text?: string;
      topicTitle?: string;
      topicContent?: string;
      threadPosts?: string;
      topicId?: string;
    };

    console.log(`[forum-ai-helper] mode=${mode}, user=${user_id}, textLen=${text?.length || 0}`);

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      throw new Error("TIMEWEB_AGENT_TOKEN not configured");
    }

    const agentId = Deno.env.get("TIMEWEB_AGENT_ID");
    if (!agentId) {
      throw new Error("TIMEWEB_AGENT_ID not configured");
    }

    const serviceName = SERVICE_NAMES[mode];
    if (!serviceName) {
      return new Response(
        JSON.stringify({ error: `Неизвестный режим: ${mode}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: service } = await supabase
      .from("addon_services")
      .select("price_rub, is_active")
      .eq("name", serviceName)
      .maybeSingle();

    if (service && !service.is_active) {
      return new Response(
        JSON.stringify({ error: "Эта функция временно отключена" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const price = service?.price_rub ?? DEFAULT_PRICES[mode];
    const isFreeMode = price === 0;

    let profile: { balance: number } | null = null;
    let newBalance = 0;

    if (!isFreeMode) {
      const { data: profileData } = await supabase
        .from("profiles")
        .select("balance")
        .eq("user_id", user_id)
        .maybeSingle();
      profile = profileData;

      if (!profile || (profile.balance || 0) < price) {
        return new Response(
          JSON.stringify({ error: "Недостаточно средств на балансе", required: price, balance: profile?.balance || 0 }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      newBalance = (profile.balance || 0) - price;
      const { error: balanceError } = await supabase
        .from("profiles")
        .update({ balance: newBalance })
        .eq("user_id", user_id);

      if (balanceError) {
        throw new Error("Ошибка списания баланса");
      }

      await supabase.from("balance_transactions").insert({
        user_id: user_id,
        amount: -price,
        balance_after: newBalance,
        type: "forum_ai",
        description: `Форум AI: ${MESSAGES[mode] || mode}`,
        metadata: { mode, topicTitle },
      });
    }

    const { systemPrompt, userPrompt } = buildPrompts(mode, text, topicTitle, topicContent, threadPosts);

    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${agentId}/v1/chat/completions`;

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
      },
      body: JSON.stringify({
        model: "deepseek-v3",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: mode === "spell_check" || mode === "auto_tags" ? 0.1 : 0.7,
      }),
    });

    console.log(`[forum-ai-helper] Timeweb response status: ${response.status}`);

    if (!response.ok) {
      if (!isFreeMode && profile) {
        await supabase
          .from("profiles")
          .update({ balance: profile.balance })
          .eq("user_id", user_id);
      }

      const errorText = await response.text();
      console.error("[forum-ai-helper] Timeweb API error:", response.status, errorText);
      throw new Error("Ошибка API — попробуйте позже");
    }

    const result = await response.json();
    const generatedContent = result.choices?.[0]?.message?.content;

    if (!generatedContent) {
      if (!isFreeMode && profile) {
        await supabase
          .from("profiles")
          .update({ balance: profile.balance })
          .eq("user_id", user_id);
      }
      throw new Error("Не удалось обработать текст");
    }

    if (mode === "auto_tags") {
      try {
        let cleanJson = generatedContent.trim();
        cleanJson = cleanJson.replace(/```json\s*/gi, "").replace(/```\s*/g, "").trim();
        const arrStart = cleanJson.indexOf("[");
        const arrEnd = cleanJson.lastIndexOf("]");
        if (arrStart !== -1 && arrEnd !== -1) {
          cleanJson = cleanJson.substring(arrStart, arrEnd + 1);
        }
        cleanJson = cleanJson
          .replace(/,\s*]/g, "]")
          .replace(/[\x00-\x1F\x7F]/g, "");

        const tags: { slug: string; name_ru: string }[] = JSON.parse(cleanJson);
        console.log(`[forum-ai-helper] auto_tags parsed ${tags.length} tags:`, tags);

        if (!Array.isArray(tags) || tags.length === 0) {
          return new Response(
            JSON.stringify({ success: true, tags: [], mode, message: "Нет подходящих тегов" }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        const createdTagIds: string[] = [];
        const createdTags: { id: string; name: string; name_ru: string; color: string }[] = [];

        for (const tag of tags.slice(0, 5)) {
          if (!tag.slug || !tag.name_ru) continue;

          const slug = tag.slug.toLowerCase().replace(/[^a-z0-9-]/g, "").slice(0, 50);
          const nameRu = tag.name_ru.trim().slice(0, 50);
          if (!slug || !nameRu) continue;

          const { data: existing } = await supabase
            .from("forum_tags")
            .select("id, name, name_ru, color")
            .eq("name", slug)
            .maybeSingle();

          if (existing) {
            createdTagIds.push(existing.id);
            createdTags.push(existing);
            await supabase
              .from("forum_tags")
              .update({ usage_count: (existing as Record<string, unknown>).usage_count ? ((existing as Record<string, unknown>).usage_count as number) + 1 : 1 })
              .eq("id", existing.id);
          } else {
            const color = TAG_COLORS[Math.floor(Math.random() * TAG_COLORS.length)];
            const { data: newTag, error: tagError } = await supabase
              .from("forum_tags")
              .insert({ name: slug, name_ru: nameRu, color, usage_count: 1 })
              .select("id, name, name_ru, color")
              .single();

            if (tagError) {
              console.error(`[forum-ai-helper] Error creating tag "${slug}":`, tagError);
              continue;
            }
            createdTagIds.push(newTag.id);
            createdTags.push(newTag);
          }
        }

        if (topicId && createdTagIds.length > 0) {
          const { data: existingLinks } = await supabase
            .from("forum_topic_tags")
            .select("tag_id")
            .eq("topic_id", topicId);

          const existingTagIds = new Set((existingLinks || []).map((l: { tag_id: string }) => l.tag_id));
          const newLinks = createdTagIds
            .filter(id => !existingTagIds.has(id))
            .slice(0, 5 - existingTagIds.size)
            .map(tag_id => ({ topic_id: topicId, tag_id }));

          if (newLinks.length > 0) {
            const { error: linkError } = await supabase
              .from("forum_topic_tags")
              .insert(newLinks);
            if (linkError) {
              console.error("[forum-ai-helper] Error linking tags:", linkError);
            }
          }
          console.log(`[forum-ai-helper] Linked ${newLinks.length} auto-tags to topic ${topicId}`);
        }

        return new Response(
          JSON.stringify({
            success: true,
            tags: createdTags,
            mode,
            message: MESSAGES[mode],
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch (parseErr) {
        console.error("[forum-ai-helper] auto_tags parse error:", parseErr, "raw:", generatedContent);
        return new Response(
          JSON.stringify({ success: true, tags: [], mode, message: "Не удалось распознать теги" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (mode === "expand_to_topic") {
      try {
        let cleanJson = generatedContent.trim();
        cleanJson = cleanJson.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
        const parsed = JSON.parse(cleanJson);
        return new Response(
          JSON.stringify({
            success: true,
            title: (parsed.title || "").trim(),
            content: (parsed.content || "").trim(),
            suggestedTags: Array.isArray(parsed.tags) ? parsed.tags : [],
            mode,
            price,
            message: MESSAGES[mode],
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch {
        const lines = generatedContent.trim().split("\n");
        const fallbackTitle = lines[0].replace(/^["#*]+|["#*]+$/g, "").trim();
        const fallbackContent = lines.slice(1).join("\n").trim();
        return new Response(
          JSON.stringify({
            success: true,
            title: fallbackTitle,
            content: fallbackContent || generatedContent.trim(),
            suggestedTags: [],
            mode,
            price,
            message: MESSAGES[mode],
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        result: generatedContent.trim(),
        mode,
        price,
        message: MESSAGES[mode],
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("[forum-ai-helper] Error:", error);
    const message = error instanceof Error ? error.message : "Неизвестная ошибка";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
