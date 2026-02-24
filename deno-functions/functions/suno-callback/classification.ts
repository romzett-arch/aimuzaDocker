import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TIMEWEB_AGENT_ACCESS_ID } from "./types.ts";

export async function classifyTrackWithAI(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  style: string | null,
  lyrics: string | null
) {
  try {
    console.log(`Starting AI classification for track ${trackId}`);

    const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
    if (!TIMEWEB_TOKEN) {
      console.error("TIMEWEB_AGENT_TOKEN not configured, skipping classification");
      return;
    }

    const [genresRes, vocalTypesRes, templatesRes, artistStylesRes] = await Promise.all([
      supabaseAdmin.from("genres").select("id, name, name_ru").order("sort_order"),
      supabaseAdmin.from("vocal_types").select("id, name, name_ru, description").eq("is_active", true).order("sort_order"),
      supabaseAdmin.from("templates").select("id, name, description").eq("is_active", true).order("sort_order"),
      supabaseAdmin.from("artist_styles").select("id, name, description").eq("is_active", true).order("sort_order"),
    ]);

    const genres = genresRes.data || [];
    const vocalTypes = vocalTypesRes.data || [];
    const templates = templatesRes.data || [];
    const artistStyles = artistStylesRes.data || [];

    if (genres.length === 0) {
      console.log("No genres in database, skipping classification");
      return;
    }

    const genresList = genres.map((g) => `- id: "${g.id}", name: "${g.name}" (${g.name_ru})`).join("\n");
    const vocalTypesList = vocalTypes
      .map((v) => `- id: "${v.id}", name: "${v.name}" (${v.name_ru})${v.description ? ` - ${v.description}` : ""}`)
      .join("\n");
    const templatesList =
      templates.length > 0
        ? templates.map((t) => `- id: "${t.id}", name: "${t.name}"${t.description ? ` - ${t.description}` : ""}`).join("\n")
        : "Нет доступных шаблонов";
    const artistStylesList =
      artistStyles.length > 0
        ? artistStyles.map((a) => `- id: "${a.id}", name: "${a.name}"${a.description ? ` - ${a.description}` : ""}`).join("\n")
        : "Нет доступных стилей артистов";

    const prompt = `Ты — музыкальный классификатор. Проанализируй стиль и лирику трека.
Выбери ОДИН наиболее подходящий вариант из каждой категории.

ЖАНРЫ (обязательно выбери один):
${genresList}

ТИПЫ ВОКАЛА (обязательно выбери один):
${vocalTypesList}

ШАБЛОНЫ (опционально, выбери если подходит):
${templatesList}

СТИЛИ АРТИСТОВ (опционально, выбери если есть явное сходство):
${artistStylesList}

---
СТИЛЬ ТРЕКА: ${style || "Не указан"}
ЛИРИКА: ${lyrics ? lyrics.substring(0, 1000) : "Инструментал (без текста)"}
---

Правила:
1. genre_id - ОБЯЗАТЕЛЕН, выбери наиболее близкий жанр
2. vocal_type_id - ОБЯЗАТЕЛЕН. Если нет лирики, выбери "instrumental"
3. template_id - только если трек явно соответствует шаблону, иначе null
4. artist_style_id - только если стиль явно похож на конкретного артиста, иначе null

Верни ТОЛЬКО JSON без markdown:
{"genre_id": "...", "vocal_type_id": "...", "template_id": "..." или null, "artist_style_id": "..." или null}`;

    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;

    const response = await fetch(apiUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TIMEWEB_TOKEN}`,
        "Content-Type": "application/json",
        "x-proxy-source": "lovable-app",
      },
      body: JSON.stringify({
        model: "deepseek-v3",
        messages: [
          { role: "system", content: "Ты музыкальный классификатор. Отвечай только JSON." },
          { role: "user", content: prompt },
        ],
        temperature: 0.3,
      }),
    });

    if (!response.ok) {
      console.error(`AI classification failed: ${response.status}`);
      return;
    }

    const result = await response.json();
    const content = result.choices?.[0]?.message?.content;

    if (!content) {
      console.error("No content in AI response");
      return;
    }

    console.log(`AI classification response: ${content}`);

    let classification;
    try {
      const jsonMatch = content.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        classification = JSON.parse(jsonMatch[0]);
      } else {
        classification = JSON.parse(content);
      }
    } catch (parseErr) {
      console.error("Failed to parse AI classification:", parseErr);
      return;
    }

    const validGenreId = genres.find((g) => g.id === classification.genre_id)?.id || null;
    const validVocalTypeId = vocalTypes.find((v) => v.id === classification.vocal_type_id)?.id || null;
    const validTemplateId = classification.template_id ? templates.find((t) => t.id === classification.template_id)?.id || null : null;
    const validArtistStyleId = classification.artist_style_id ? artistStyles.find((a) => a.id === classification.artist_style_id)?.id || null : null;

    const updateData: Record<string, string | null> = {};
    if (validGenreId) updateData.genre_id = validGenreId;
    if (validVocalTypeId) updateData.vocal_type_id = validVocalTypeId;
    if (validTemplateId) updateData.template_id = validTemplateId;
    if (validArtistStyleId) updateData.artist_style_id = validArtistStyleId;

    if (Object.keys(updateData).length > 0) {
      const { error: updateErr } = await supabaseAdmin.from("tracks").update(updateData).eq("id", trackId);

      if (updateErr) {
        console.error("Failed to update track classification:", updateErr);
      } else {
        console.log(`Track ${trackId} classified: genre=${validGenreId}, vocal=${validVocalTypeId}, template=${validTemplateId}, artist=${validArtistStyleId}`);
      }
    }
  } catch (err) {
    console.error("Error in AI classification:", err);
  }
}

export async function processTrackAddons(
  supabaseAdmin: SupabaseClient,
  trackId: string,
  trackTitle: string,
  coverUrl: string | null,
  audioUrl: string | null,
  sunoTaskId?: string,
  sunoAudioId?: string
) {
  try {
    const { data: trackAddons, error: addonsError } = await supabaseAdmin
      .from("track_addons")
      .select(
        `
        id,
        addon_service_id,
        status,
        addon_service:addon_services(name, name_ru)
      `
      )
      .eq("track_id", trackId)
      .eq("status", "pending");

    if (addonsError) {
      console.error("Error fetching track addons:", addonsError);
      return;
    }

    if (!trackAddons || trackAddons.length === 0) {
      console.log(`No pending addons for track ${trackId}`);
      return;
    }

    console.log(`Processing ${trackAddons.length} addons for track ${trackId}`);

    const { data: track } = await supabaseAdmin
      .from("tracks")
      .select("genre_id, genres(name)")
      .eq("id", trackId)
      .single();

    const genreData = (track?.genres as unknown) as { name: string } | null;
    const genreName = genreData?.name || "electronic";

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    for (const addon of trackAddons) {
      const addonServiceData = (addon.addon_service as unknown) as { name: string; name_ru: string } | null;
      const addonName = addonServiceData?.name;
      console.log(`Processing addon: ${addonName} for track ${trackId}`);

      await supabaseAdmin
        .from("track_addons")
        .update({ status: "processing", updated_at: new Date().toISOString() })
        .eq("id", addon.id);

      let functionName: string | null = null;
      let requestBody: Record<string, unknown> = {
        track_id: trackId,
        track_title: trackTitle,
        genre: genreName,
      };

      if (addonName === "large_cover") {
        functionName = "generate-hd-cover";
        requestBody.original_cover_url = coverUrl;
      } else if (addonName === "short_video") {
        functionName = "generate-short-video";
        requestBody.cover_url = coverUrl;
        if (sunoTaskId) {
          requestBody.suno_task_id = sunoTaskId;
        }
        if (sunoAudioId) {
          requestBody.suno_audio_id = sunoAudioId;
        }
      } else if (addonName === "ringtone") {
        functionName = "generate-ringtone";
        requestBody.audio_url = audioUrl;
      }

      if (functionName) {
        try {
          const response = await fetch(`${SUPABASE_URL}/functions/v1/${functionName}`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
            },
            body: JSON.stringify(requestBody),
          });

          const result = await response.json();
          console.log(`${functionName} result for track ${trackId}:`, result);

          if (!result.success) {
            await supabaseAdmin
              .from("track_addons")
              .update({
                status: "failed",
                updated_at: new Date().toISOString(),
              })
              .eq("id", addon.id);
          }
        } catch (fnError) {
          console.error(`Error calling ${functionName}:`, fnError);
          await supabaseAdmin
            .from("track_addons")
            .update({
              status: "failed",
              updated_at: new Date().toISOString(),
            })
            .eq("id", addon.id);
        }
      } else {
        console.log(`Unknown addon type: ${addonName}, marking as failed`);
        await supabaseAdmin
          .from("track_addons")
          .update({
            status: "failed",
            updated_at: new Date().toISOString(),
          })
          .eq("id", addon.id);
      }
    }
  } catch (error) {
    console.error("Error processing track addons:", error);
  }
}
