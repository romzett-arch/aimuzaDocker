/**
 * D4: AI-антифрод конкурсов
 * SQL-правила + DeepSeek при аномалиях. Результат в contest_entries.fraud_flags
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};


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

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: adminCheck } = await supabase.rpc("is_admin" as any, { _user_id: user.id });
    if (!adminCheck) {
      return new Response(
        JSON.stringify({ error: "Admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json().catch(() => ({}));
    const { contest_id } = body;
    if (!contest_id) {
      return new Response(
        JSON.stringify({ error: "contest_id required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: setting } = await supabase
      .from("forum_automod_settings")
      .select("value")
      .eq("key", "contest_antifraud")
      .maybeSingle();

    const config = setting?.value as { enabled?: boolean } | null;
    if (!config?.enabled) {
      return new Response(
        JSON.stringify({ error: "contest_antifraud not enabled" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: entries } = await supabase
      .from("contest_entries")
      .select("id, user_id, votes_count, track_id")
      .eq("contest_id", contest_id)
      .eq("status", "active");

    if (!entries?.length) {
      return new Response(
        JSON.stringify({ success: true, flags: {}, message: "Нет участников" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: votes } = await supabase
      .from("contest_votes")
      .select("entry_id, user_id, created_at")
      .eq("contest_id", contest_id);

    const totalVotes = votes?.length || 0;
    if (totalVotes === 0) {
      return new Response(
        JSON.stringify({ success: true, flags: {}, message: "Нет голосов" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const voterIds = [...new Set((votes || []).map((v) => v.user_id))];
    const { data: profiles } = await supabase
      .from("profiles")
      .select("user_id, created_at")
      .in("user_id", voterIds);

    const profileCreated = new Map<string, string>();
    profiles?.forEach((p) => profileCreated.set(p.user_id, p.created_at || ""));

    const now = new Date();
    const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
    const twoHoursAgo = new Date(now.getTime() - 2 * 60 * 60 * 1000);

    const flags: Record<string, { rule_id: string; severity: string; detail: string; ai_verdict?: string }[]> = {};
    let hasAnomalies = false;

    for (const entry of entries || []) {
      const entryVotes = votes?.filter((v) => v.entry_id === entry.id) || [];
      const entryFlags: { rule_id: string; severity: string; detail: string; ai_verdict?: string }[] = [];

      const selfVotes = entryVotes.filter((v) => v.user_id === entry.user_id);
      if (selfVotes.length > 0) {
        entryFlags.push({
          rule_id: "self_vote",
          severity: "high",
          detail: `Обнаружены голоса от автора записи (${selfVotes.length})`,
        });
        hasAnomalies = true;
      }

      const newAccountVotes = entryVotes.filter((v) => {
        const created = profileCreated.get(v.user_id);
        return created && new Date(created) > sevenDaysAgo;
      });
      const newAccountRatio = entryVotes.length > 0 ? newAccountVotes.length / entryVotes.length : 0;
      if (newAccountRatio > 0.5 && entryVotes.length >= 5) {
        entryFlags.push({
          rule_id: "new_account_ratio",
          severity: "medium",
          detail: `${Math.round(newAccountRatio * 100)}% голосов от аккаунтов младше 7 дней`,
        });
        hasAnomalies = true;
      }

      const burstVotes = entryVotes.filter((v) => new Date(v.created_at) > twoHoursAgo);
      if (burstVotes.length >= 10 && burstVotes.length / entryVotes.length > 0.7) {
        entryFlags.push({
          rule_id: "vote_burst",
          severity: "medium",
          detail: `${burstVotes.length} голосов за последние 2 часа (${Math.round((burstVotes.length / entryVotes.length) * 100)}% от всех)`,
        });
        hasAnomalies = true;
      }

      const voteShare = totalVotes > 0 ? (entryVotes.length / totalVotes) * 100 : 0;
      if (voteShare > 80 && totalVotes >= 20) {
        entryFlags.push({
          rule_id: "dominant_share",
          severity: "low",
          detail: `Одна запись получила ${voteShare.toFixed(0)}% всех голосов`,
        });
      }

      if (entryFlags.length > 0) {
        flags[entry.id] = entryFlags;
      }
    }

    let aiVerdict: string | null = null;
    if (hasAnomalies) {
      const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
      if (TIMEWEB_TOKEN) {
        const summary = Object.entries(flags)
          .map(([eid, fl]) => {
            const entry = entries?.find((x) => x.id === eid);
            return `Запись ${entry?.track_id || eid}: ${fl.map((f) => f.detail).join("; ")}`;
          })
          .join("\n");

        const systemPrompt = `Ты эксперт по выявлению накрутки голосов в музыкальных конкурсах.
Дай краткий вердикт (2-3 предложения) на русском: насколько вероятна накрутка, что рекомендовать модератору.`;

        const userPrompt = `Обнаружены аномалии в голосовании:\n\n${summary}\n\nВердикт:`;

        const agentId = Deno.env.get("TIMEWEB_AGENT_ID") || "";
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
            temperature: 0.2,
            max_tokens: 200,
          }),
        });

        if (response.ok) {
          const data = await response.json();
          aiVerdict = data.choices?.[0]?.message?.content?.trim() || null;
        }
      }
    }

    const fraudFlagsValue = {
      checked_at: new Date().toISOString(),
      total_votes: totalVotes,
      entries_flagged: Object.keys(flags).length,
      flags,
      ai_verdict: aiVerdict,
    };

    for (const entry of entries || []) {
      const entryFlags = flags[entry.id];
      const fraudData = entryFlags
        ? {
            ...fraudFlagsValue,
            entry_flags: entryFlags,
            ai_verdict: aiVerdict,
          }
        : { ...fraudFlagsValue, entry_flags: [] };

      await supabase
        .from("contest_entries")
        .update({ fraud_flags: fraudData })
        .eq("id", entry.id);
    }

    return new Response(
      JSON.stringify({
        success: true,
        total_votes: totalVotes,
        entries_flagged: Object.keys(flags).length,
        flags,
        ai_verdict: aiVerdict,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[contest-antifraud] Error:", error);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
