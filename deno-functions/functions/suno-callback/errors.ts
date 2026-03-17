import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { TrackToFail } from "./types.ts";

export function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();

    if (
      lowerMsg.includes("matches existing work") ||
      lowerMsg.includes("existing work of art") ||
      lowerMsg.includes("copyright") ||
      lowerMsg.includes("protected content")
    ) {
      return {
        short: "Контент защищён авторским правом",
        full: "Загруженный аудиофайл или текст распознан как существующее произведение. Система защиты авторских прав Suno заблокировала генерацию. Попробуйте использовать оригинальный контент.",
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

    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Сократите текст и попробуйте снова.",
      };
    }

    if (lowerMsg.includes("credit") || lowerMsg.includes("balance") || lowerMsg.includes("insufficient")) {
      return {
        short: "Недостаточно кредитов Suno",
        full: "На аккаунте Suno недостаточно кредитов для генерации. Обратитесь в поддержку.",
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
      full: "Проблема с авторизацией в сервисе Suno. Обратитесь в поддержку.",
    },
    403: {
      short: "Контент заблокирован модерацией",
      full: "Ваш запрос содержит запрещённый контент или нарушает правила использования Suno. Измените текст или описание.",
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
      short: "Превышен лимит символов",
      full: "Описание, стиль или текст песни слишком длинные для обработки. Сократите текст (макс. ~3000 символов для lyrics, ~200 для style) и попробуйте снова.",
    },
    429: {
      short: "Недостаточно кредитов",
      full: "На аккаунте Suno недостаточно кредитов для генерации. Обратитесь в поддержку.",
    },
    455: {
      short: "Сервис на обслуживании",
      full: "Сервис Suno проходит техническое обслуживание. Попробуйте позже.",
    },
    500: {
      short: "Внутренняя ошибка сервера",
      full: "Произошла внутренняя ошибка на сервере Suno. Попробуйте позже.",
    },
    503: {
      short: "Сервис временно недоступен",
      full: "Сервис Suno временно перегружен или на обслуживании. Попробуйте позже.",
    },
  };

  if (errorMessages[code]) {
    return errorMessages[code];
  }

  return {
    short: `Ошибка генерации (код ${code})`,
    full: originalMessage || `Произошла ошибка при генерации. Код ошибки: ${code}. Попробуйте позже или обратитесь в поддержку.`,
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
