import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { TrackToFail } from "./types.ts";

function extractBlockedArtistName(originalMessage?: string): string | null {
  if (!originalMessage) return null;

  const match = originalMessage.match(/artist name\s+([^.,!]+?)(?:\s*-\s*we don't reference|\s+please change|[.,!]|$)/i);
  return match?.[1]?.trim() || null;
}

export function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();
    const blockedArtistName = extractBlockedArtistName(originalMessage);

    if (
      lowerMsg.includes("matches existing work") ||
      lowerMsg.includes("matches an existing recording") ||
      lowerMsg.includes("existing work of art") ||
      lowerMsg.includes("existing recording in our catalog") ||
      lowerMsg.includes("copyright") ||
      lowerMsg.includes("protected content")
    ) {
      return {
        short: "Контент защищён авторским правом",
        full: "Загруженный аудиофайл или текст распознан как существующее произведение. Система защиты авторских прав AIMUZA заблокировала генерацию. Попробуйте использовать оригинальный контент.",
      };
    }

    if (blockedArtistName || lowerMsg.includes("artist name")) {
      const quotedName = blockedArtistName ? ` «${blockedArtistName}»` : "";
      return {
        short: `AIMUZA отклонила описание: найдено имя артиста${quotedName}`,
        full: `AIMUZA посчитала часть описания или стиля ссылкой на конкретного артиста${quotedName}. Уберите это слово или замените формулировку на более нейтральную и запустите генерацию снова.`,
      };
    }

    if (
      lowerMsg.includes("moderation") ||
      lowerMsg.includes("sensitive") ||
      lowerMsg.includes("inappropriate") ||
      lowerMsg.includes("prohibited")
    ) {
      return {
        short: "Контент не прошёл модерацию",
        full: "Текст или описание содержит запрещённые слова или фразы. Измените содержимое и попробуйте снова.",
      };
    }

    if (lowerMsg.includes("fetch") && lowerMsg.includes("audio")) {
      return {
        short: "Не удалось получить аудиофайл",
        full: "Сервер не смог загрузить ваш аудиофайл. Проверьте, что файл доступен и попробуйте снова.",
      };
    }

    if (
      lowerMsg.includes("couldn't verify your audio") ||
      lowerMsg.includes("could not verify your audio") ||
      lowerMsg.includes("verify your audio")
    ) {
      return {
        short: "AIMUZA не смогла проверить аудио",
        full: "AIMUZA не смогла проверить загруженный аудиореференс. Попробуйте загрузить другой файл или предварительно экспортировать его заново в MP3/WAV.",
      };
    }

    if (
      lowerMsg.includes("can't parse uploaded audio") ||
      lowerMsg.includes("cannot parse uploaded audio") ||
      lowerMsg.includes("source is corrupted") ||
      lowerMsg.includes("corrupted")
    ) {
      return {
        short: "AIMUZA не смогла прочитать аудиофайл",
        full: "AIMUZA считает загруженный аудиофайл повреждённым или неподдерживаемым. Экспортируйте файл заново в MP3/WAV и повторите генерацию.",
      };
    }

    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Для генерации по аудиореференсу в V5/V5.5 лимиты AIMUZA: до 5000 символов текста и до 1000 символов стиля.",
      };
    }

    if (lowerMsg.includes("credit") || lowerMsg.includes("balance") || lowerMsg.includes("insufficient")) {
      return {
        short: "Генерация временно недоступна",
        full: "Генерация AIMUZA временно недоступна. Обратитесь в поддержку.",
      };
    }
  }

  const errorMessages: Record<number, { short: string; full: string }> = {
    400: {
      short: "Неверные параметры запроса",
      full: "Параметры генерации некорректны. Проверьте введённые данные и попробуйте снова.",
    },
    401: {
      short: "Ошибка авторизации",
      full: "Проблема с авторизацией в сервисе AIMUZA. Обратитесь в поддержку.",
    },
    403: {
      short: "Контент заблокирован модерацией",
      full: "Ваш запрос содержит запрещённый контент или нарушает правила использования AIMUZA. Измените текст или описание.",
    },
    404: {
      short: "Ресурс не найден",
      full: "Запрашиваемый ресурс не найден. Попробуйте ещё раз.",
    },
    405: {
      short: "Превышена частота запросов",
      full: "Слишком много запросов к API. Подождите несколько минут и попробуйте снова.",
    },
    413: {
      short: "AIMUZA отклонила запрос",
      full: originalMessage
        ? `AIMUZA отклонила запрос: ${originalMessage.replace(/suno/gi, "AIMUZA")}`
        : "AIMUZA отклонила запрос с кодом 413. Для генерации по аудиореференсу этот код может означать не только лимит текста, но и проблему с аудиофайлом или проверкой контента.",
    },
    429: {
      short: "Недостаточно кредитов",
      full: "Генерация AIMUZA временно недоступна. Обратитесь в поддержку.",
    },
    455: {
      short: "Сервис на обслуживании",
      full: "Сервис AIMUZA проходит техническое обслуживание. Попробуйте позже.",
    },
    500: {
      short: "Внутренняя ошибка сервера",
      full: "Произошла внутренняя ошибка на сервере AIMUZA. Попробуйте позже.",
    },
    503: {
      short: "Сервис временно недоступен",
      full: "Сервис AIMUZA временно перегружен или на обслуживании. Попробуйте позже.",
    },
  };

  if (errorMessages[code]) {
    return errorMessages[code];
  }

  return {
    short: `Ошибка генерации (код ${code})`,
    full: originalMessage?.replace(/suno/gi, "AIMUZA") || `Произошла ошибка при генерации. Код ошибки: ${code}. Попробуйте позже или обратитесь в поддержку.`,
  };
}

export async function handleFailedTracksWithRefunds(
  supabaseAdmin: SupabaseClient,
  tracksToFail: TrackToFail[],
  failReason: string,
  errorInfo: { short: string; full: string }
): Promise<void> {
  for (const track of tracksToFail) {
    await supabaseAdmin
      .from("tracks")
      .update({
        status: "failed",
        error_message: failReason,
      })
      .eq("id", track.id);

    const { data: genLog } = await supabaseAdmin
      .from("generation_logs")
      .select("cost_rub")
      .eq("track_id", track.id)
      .eq("status", "pending")
      .maybeSingle();

    if (genLog && genLog.cost_rub > 0) {
      const { error: refundError } = await supabaseAdmin.rpc("refund_generation_failed", {
        p_user_id: track.user_id,
        p_amount: genLog.cost_rub,
        p_track_id: track.id,
        p_description: `Возврат за генерацию: ${failReason}`,
      });

      if (refundError) {
        console.error(`Refund failed for track ${track.id}:`, refundError);
      } else {
        console.log(`Refunded ${genLog.cost_rub} ₽ to user ${track.user_id}`);

        await supabaseAdmin.from("notifications").insert({
          user_id: track.user_id,
          type: "refund",
          title: `Ошибка: ${failReason}`,
          message: `${errorInfo.full}\n\nВам возвращено ${genLog.cost_rub} ₽`,
          target_type: "track",
          target_id: track.id,
        });
      }
    }

    await supabaseAdmin
      .from("generation_logs")
      .update({ status: "failed" })
      .eq("track_id", track.id)
      .eq("status", "pending");
  }
}
