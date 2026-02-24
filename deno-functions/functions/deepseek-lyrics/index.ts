import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, DEEPSEEK_AGENT_ID } from "./types.ts";
import type { RequestBody } from "./types.ts";
import { checkAndDeductBalance } from "./billing.ts";
import { buildPrompts } from "./prompts.ts";

const modelName = "deepseek-v3.2";

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
    const body = await req.json() as RequestBody;
    const { mode, lyrics, style, theme, autoEval } = body;

    console.log("Timeweb lyrics request:", { mode, user_id, agent: 'DeepSeek', hasLyrics: !!lyrics, style, theme });

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      throw new Error("DeepSeek token not configured");
    }

    const skipBilling = autoEval === true && (mode === "analyze_prompt" || mode === "analyze_style");

    const billingResult = await checkAndDeductBalance(supabase, user_id, mode, skipBilling);
    if (billingResult.error) {
      const status = billingResult.error === "Недостаточно средств на балансе" ? 402 : 500;
      return new Response(
        JSON.stringify({ error: billingResult.error }),
        { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { previousBalance } = billingResult;
    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${DEEPSEEK_AGENT_ID}/v1/chat/completions`;

    if (mode === "improve") {
      const pass1 = buildPrompts(mode, body, { pass: 1 });
      console.log("IMPROVE PASS 1 (structure): calling API...");
      const imp1Response = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: pass1.systemPrompt }, { role: "user", content: pass1.userPrompt }],
          temperature: 0.6,
        }),
      });

      if (!imp1Response.ok) {
        await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
        console.error("Improve Pass 1 error:", imp1Response.status);
        throw new Error("Ошибка API (улучшение, проход 1)");
      }

      const imp1Result = await imp1Response.json();
      const imp1Text = imp1Result.choices?.[0]?.message?.content;
      if (!imp1Text) {
        await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
        throw new Error("Не удалось улучшить текст (проход 1)");
      }
      console.log("IMPROVE PASS 1 done, length:", imp1Text.length);

      const pass2 = buildPrompts(mode, body, { pass: 2, intermediateText: imp1Text });
      console.log("IMPROVE PASS 2 (imagery): calling API...");
      const imp2Response = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: pass2.systemPrompt }, { role: "user", content: pass2.userPrompt }],
          temperature: 0.8,
        }),
      });

      let improvedText: string;
      if (!imp2Response.ok) {
        console.error("Improve Pass 2 failed, using pass 1 result");
        improvedText = imp1Text;
      } else {
        const imp2Result = await imp2Response.json();
        improvedText = imp2Result.choices?.[0]?.message?.content || imp1Text;
      }
      console.log("IMPROVE PASS 2 done, length:", improvedText.length);

      await supabase.from("generated_lyrics").insert({
        user_id, prompt: `[IMPROVE-2PASS] ${style || ""}`, lyrics: improvedText, title: null,
      });

      return new Response(
        JSON.stringify({ success: true, lyrics: improvedText.trim(), mode, message: "Текст улучшен!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (mode === "fix_pronunciation") {
      const { systemPrompt, userPrompt } = buildPrompts(mode, body);
      console.log("FIX_PRONUNCIATION: calling API...");
      const pronResponse = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: systemPrompt }, { role: "user", content: userPrompt }],
          temperature: 0.2,
        }),
      });

      if (!pronResponse.ok) {
        await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
        console.error("Fix pronunciation error:", pronResponse.status);
        throw new Error("Ошибка API (исправление произношения)");
      }

      const pronResult = await pronResponse.json();
      const fixedText = pronResult.choices?.[0]?.message?.content;
      if (!fixedText) {
        await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
        throw new Error("Не удалось исправить произношение");
      }
      console.log("FIX_PRONUNCIATION done, length:", fixedText.length);

      return new Response(
        JSON.stringify({ success: true, lyrics: fixedText.trim(), mode, message: "Произношение исправлено!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (mode === "generate") {
      const pass1 = buildPrompts(mode, body, { pass: 1 });
      console.log("PASS 1 (structure): calling API...");
      const pass1Response = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: pass1.systemPrompt }, { role: "user", content: pass1.userPrompt }],
          temperature: 0.6,
        }),
      });

      if (!pass1Response.ok) {
        await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
        const errorText = await pass1Response.text();
        console.error("Pass 1 API error:", pass1Response.status, errorText);
        throw new Error("Ошибка API (проход 1)");
      }

      const pass1Result = await pass1Response.json();
      const pass1Text = pass1Result.choices?.[0]?.message?.content;
      if (!pass1Text) {
        await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
        throw new Error("Не удалось сгенерировать структуру текста");
      }
      console.log("PASS 1 done, length:", pass1Text.length);

      const pass2 = buildPrompts(mode, body, { pass: 2, intermediateText: pass1Text });
      console.log("PASS 2 (imagery): calling API...");
      const pass2Response = await fetch(apiUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
        body: JSON.stringify({
          model: modelName,
          messages: [{ role: "system", content: pass2.systemPrompt }, { role: "user", content: pass2.userPrompt }],
          temperature: 0.8,
        }),
      });

      let finalText: string;
      if (!pass2Response.ok) {
        console.error("Pass 2 failed, returning pass 1 result");
        finalText = pass1Text;
        await supabase.from("generated_lyrics").insert({
          user_id, prompt: `[GENERATE-2PASS-FALLBACK] ${theme || style || ""}`, lyrics: finalText, title: null,
        });
        return new Response(
          JSON.stringify({ success: true, lyrics: finalText, mode, message: "Текст создан!" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const pass2Result = await pass2Response.json();
      finalText = pass2Result.choices?.[0]?.message?.content || pass1Text;
      console.log("PASS 2 done, length:", finalText.length);

      await supabase.from("generated_lyrics").insert({
        user_id, prompt: `[GENERATE-2PASS] ${theme || style || ""}`, lyrics: finalText, title: null,
      });

      return new Response(
        JSON.stringify({ success: true, lyrics: finalText.trim(), mode, message: "Текст создан!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { systemPrompt, userPrompt } = buildPrompts(mode, body);
    console.log(`Calling DeepSeek agent: ${DEEPSEEK_AGENT_ID}`);

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${TIMEWEB_TOKEN}` },
      body: JSON.stringify({
        model: modelName,
        messages: [{ role: "system", content: systemPrompt }, { role: "user", content: userPrompt }],
        temperature: 0.8,
      }),
    });

    console.log("Timeweb response status:", response.status);

    if (!response.ok) {
      await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
      const errorText = await response.text();
      console.error("Timeweb API error:", response.status, errorText);
      throw new Error("Ошибка API Timeweb");
    }

    const result = await response.json();
    console.log("Timeweb response received");

    const generatedContent = result.choices?.[0]?.message?.content;

    if (!generatedContent) {
      await supabase.from("profiles").update({ balance: previousBalance }).eq("user_id", user_id);
      throw new Error("Не удалось сгенерировать текст");
    }

    const isB9Mode = ["suggest_tags", "build_style", "analyze_style", "analyze_prompt", "auto_tag_all"].includes(mode);
    if (mode !== "create_prompt" && mode !== "markup" && !isB9Mode) {
      await supabase.from("generated_lyrics").insert({
        user_id, prompt: mode === "improve" ? `[IMPROVE] ${style || ""}` : `[GENERATE] ${theme || style || ""}`,
        lyrics: generatedContent, title: null,
      });
    }

    if (mode === "create_prompt") {
      return new Response(
        JSON.stringify({ success: true, stylePrompt: generatedContent.trim(), mode, message: "Промт создан!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (mode === "markup") {
      return new Response(
        JSON.stringify({ success: true, lyrics: generatedContent.trim(), mode, message: "Текст размечен!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (isB9Mode) {
      let jsonStr = generatedContent.trim();
      const jsonMatch = jsonStr.match(/```(?:json)?\s*([\s\S]*?)```/);
      if (jsonMatch) jsonStr = jsonMatch[1].trim();
      try {
        const parsed = JSON.parse(jsonStr);
        return new Response(
          JSON.stringify({ success: true, ...parsed, mode }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch (e) {
        console.error("B9 JSON parse error:", e);
        return new Response(
          JSON.stringify({ error: "Не удалось разобрать ответ AI", raw: generatedContent.slice(0, 500) }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (mode === "ideas") {
      const ideas: Array<{ title: string; mood: string; concept: string; tags: string; lyrics: string }> = [];
      const ideaBlocks = generatedContent.split(/---IDEA_\d+---/).filter((b: string) => b.trim());

      for (const block of ideaBlocks) {
        const titleMatch = block.match(/НАЗВАНИЕ:\s*(.+)/i);
        const moodMatch = block.match(/НАСТРОЕНИЕ:\s*(.+)/i);
        const conceptMatch = block.match(/КОНЦЕПЦИЯ:\s*(.+)/i);
        const tagsMatch = block.match(/ТЕГИ:\s*(.+)/i);
        const lyricsMatch = block.match(/ТЕКСТ:\s*([\s\S]+?)(?=(?:---IDEA_|$))/i);

        if (titleMatch) {
          ideas.push({
            title: titleMatch[1].trim(),
            mood: moodMatch?.[1]?.trim() || "",
            concept: conceptMatch?.[1]?.trim() || "",
            tags: tagsMatch?.[1]?.trim() || "",
            lyrics: lyricsMatch?.[1]?.trim() || "",
          });
        }
      }

      return new Response(
        JSON.stringify({ success: true, ideas, mode, message: "Идеи сгенерированы!" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, lyrics: generatedContent.trim(), mode, message: mode === "improve" ? "Текст улучшен!" : "Текст сгенерирован!" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error: unknown) {
    console.error("Error in deepseek-lyrics:", error);
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
