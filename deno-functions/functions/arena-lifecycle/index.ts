/**
 * arena-lifecycle — Deno Edge Function
 * Вызывается по cron (каждые 5 минут) или вручную (admin)
 * Обрабатывает:
 *  1. Переход active → voting (по end_date)
 *  2. Автофинализация voting → completed
 *  3. Обновление статусов сезонов
 *  4. Создание daily challenge (если нет активного)
 *  5. Сброс weekly_points по понедельникам
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || Deno.env.get("API_URL") || "http://api:3000";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SERVICE_ROLE_KEY") || "";

    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: { persistSession: false },
    });

    const results: string[] = [];

    // 1. Process contest lifecycle (active→voting→completed, seasons)
    const { data: lifecycleCount, error: lcErr } = await supabase.rpc("process_contest_lifecycle");
    if (lcErr) {
      results.push(`lifecycle error: ${lcErr.message}`);
    } else {
      results.push(`lifecycle processed: ${lifecycleCount} contests`);
    }

    // 2. Create daily challenge if none exists
    const today = new Date();
    const todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    const todayEnd = new Date(todayStart.getTime() + 24 * 60 * 60 * 1000);
    const votingEnd = new Date(todayEnd.getTime() + 12 * 60 * 60 * 1000); // +12h for voting

    const { data: existingDaily } = await supabase
      .from("contests")
      .select("id")
      .eq("contest_type", "daily")
      .gte("start_date", todayStart.toISOString())
      .limit(1);

    if (!existingDaily || existingDaily.length === 0) {
      // Get random theme for today
      const themes = [
        "Утренняя энергия", "Ночной вайб", "Дорожное приключение",
        "Мечтательное настроение", "Танцевальный бит", "Лирическая история",
        "Ретро волна", "Электронный рассвет", "Акустическая душа",
        "Городской ритм", "Космическое путешествие", "Летний закат",
        "Зимняя сказка", "Весеннее пробуждение", "Осенняя меланхолия",
        "Любовная серенада", "Бунтарский дух", "Тихая гавань",
        "Неоновые огни", "Свободный полёт",
      ];
      const theme = themes[today.getDate() % themes.length];
      const dayOfWeek = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"][today.getDay()];
      const dayNum = today.getDate();
      const monthNames = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"];

      const { error: createErr } = await supabase
        .from("contests")
        .insert({
          title: `Daily Challenge: ${theme}`,
          description: `Ежедневный вызов ${dayNum} ${monthNames[today.getMonth()]}. Создайте трек на тему «${theme}» и победите!`,
          contest_type: "daily",
          status: "active",
          start_date: todayStart.toISOString(),
          end_date: todayEnd.toISOString(),
          voting_end_date: votingEnd.toISOString(),
          theme,
          prize_amount: 50,
          prize_pool_formula: "fixed",
          prize_distribution: [0.6, 0.3, 0.1],
          max_entries_per_user: 1,
          entry_fee: 0,
          min_participants: 3,
          auto_finalize: true,
          require_new_track: true,
          scoring_mode: "votes",
          created_by: null,
        });

      if (createErr) {
        results.push(`daily create error: ${createErr.message}`);
      } else {
        results.push(`daily challenge created: ${theme}`);
      }
    } else {
      results.push("daily challenge already exists");
    }

    // 3. Weekly reset (Monday at 00:00)
    if (today.getDay() === 1 && today.getHours() < 1) {
      const { error: resetErr } = await supabase
        .from("contest_ratings")
        .update({ weekly_points: 0 })
        .gt("weekly_points", 0);

      if (resetErr) {
        results.push(`weekly reset error: ${resetErr.message}`);
      } else {
        results.push("weekly points reset");
      }
    }

    // 4. Check achievements for recently active users
    const { data: recentEntries } = await supabase
      .from("contest_entries")
      .select("user_id")
      .gte("created_at", new Date(Date.now() - 10 * 60 * 1000).toISOString())
      .limit(50);

    if (recentEntries && recentEntries.length > 0) {
      const uniqueUsers = [...new Set(recentEntries.map((e: any) => e.user_id))];
      let achievementsAwarded = 0;
      for (const uid of uniqueUsers) {
        const { data: count } = await supabase.rpc("check_contest_achievements", { p_user_id: uid });
        achievementsAwarded += (count || 0);
      }
      results.push(`achievements checked for ${uniqueUsers.length} users, awarded ${achievementsAwarded}`);
    }

    return new Response(
      JSON.stringify({ ok: true, results, timestamp: new Date().toISOString() }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});
