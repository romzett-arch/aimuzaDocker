import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { AutomodRequest, AutomodResult } from "./types.ts";
import { corsHeaders } from "./types.ts";
import { humanizeFlag, jsonResponse } from "./utils.ts";
import {
  checkRateLimit,
  checkStopwords,
  checkLinks,
  checkRegex,
  checkNewbie,
  checkDuplicate,
  checkAdPolicy,
  checkAIToxicity,
  checkAISpam,
  checkAIQuality,
} from "./checks.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ allowed: false, reason: "unauthorized", message: "Необходимо войти в систему" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      console.error("Auth error:", authError);
      return new Response(
        JSON.stringify({ allowed: false, reason: "unauthorized", message: "Не авторизован" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body: AutomodRequest = await req.json();
    const { content, title, type } = body;
    const textToCheck = title ? `${title} ${content}` : content;
    const flags: string[] = [];
    let autoHidden = false;

    console.log(`[forum-automod] Checking ${type} from user ${user.id}, length: ${textToCheck.length}`);

    const { data: settings } = await supabase
      .from("forum_automod_settings")
      .select("key, value");

    const settingsMap: Record<string, any> = {};
    (settings || []).forEach((s: any) => { settingsMap[s.key] = s.value; });

    const { data: userStats } = await supabase
      .from("forum_user_stats")
      .select("trust_level")
      .eq("user_id", user.id)
      .maybeSingle();
    const userTrustLevel = userStats?.trust_level ?? 0;

    const result1 = await checkRateLimit(supabase, user.id);
    if (result1) return jsonResponse(result1);

    checkStopwords(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    checkLinks(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    checkRegex(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    await checkNewbie(supabase, settingsMap, user.id, userTrustLevel, flags, (v: boolean) => { autoHidden = autoHidden || v; });

    const dupResult = await checkDuplicate(supabase, user.id, textToCheck);
    if (dupResult) return jsonResponse(dupResult);

    const adResult = await checkAdPolicy(supabase, settingsMap, user.id, userTrustLevel, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    if (adResult) return jsonResponse(adResult);

    const aiTrustThreshold = settingsMap["ai_moderation"]?.skip_trust_level ?? 2;
    if (userTrustLevel < aiTrustThreshold) {
      console.log(`[forum-automod] Running AI checks for user trust_level=${userTrustLevel} (threshold=${aiTrustThreshold})`);
      await checkAIToxicity(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
      await checkAISpam(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
      await checkAIQuality(settingsMap, textToCheck, flags, (v: boolean) => { autoHidden = autoHidden || v; });
    } else {
      console.log(`[forum-automod] Skipping AI checks for trusted user trust_level=${userTrustLevel}`);
    }

    const humanFlags = flags.map(f => humanizeFlag(f));
    const result: AutomodResult = {
      allowed: true,
      flags: flags.length > 0 ? flags : undefined,
      human_flags: humanFlags.length > 0 ? humanFlags : undefined,
      auto_hidden: autoHidden || undefined,
    };

    if (autoHidden) {
      result.message = "Контент будет проверен модератором";
      result.hidden_reason = humanFlags.length > 0
        ? `Сообщение скрыто: ${humanFlags.join(", ").toLowerCase()}`
        : "Сообщение скрыто автоматической модерацией";
      console.log(`[forum-automod] Content flagged for auto-hide: ${flags.join(", ")}`);
    }

    console.log(`[forum-automod] Result: allowed=${result.allowed}, flags=${flags.join(",")}, auto_hidden=${autoHidden}`);
    return jsonResponse(result);

  } catch (error) {
    console.error("[forum-automod] Error:", error);
    return jsonResponse({ allowed: true, error: "Automod check failed, allowing by default" });
  }
});
