function extractBlockedArtistName(originalMessage?: string): string | null {
  if (!originalMessage) return null;

  const match = originalMessage.match(/artist name\s+([^.,!]+?)(?:\s*-\s*we don't reference|\s+please change|[.,!]|$)/i);
  return match?.[1]?.trim() || null;
}

export function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();
    const blockedArtistName = extractBlockedArtistName(originalMessage);

    if (lowerMsg.includes("matches existing work") ||
        lowerMsg.includes("matches an existing recording") ||
        lowerMsg.includes("existing work of art") ||
        lowerMsg.includes("existing recording in our catalog") ||
        lowerMsg.includes("copyright") ||
        lowerMsg.includes("protected content")) {
      return {
        short: "Контент защищён авторским правом",
        full: "Загруженный аудиофайл или текст распознан как существующее произведение. Попробуйте использовать оригинальный контент."
      };
    }

    if (blockedArtistName || lowerMsg.includes("artist name")) {
      const quotedName = blockedArtistName ? ` «${blockedArtistName}»` : "";
      return {
        short: `Suno отклонил описание: найдено имя артиста${quotedName}`,
        full: `Suno посчитал часть описания или стиля ссылкой на конкретного артиста${quotedName}. Уберите это слово или замените формулировку на более нейтральную и запустите генерацию снова.`
      };
    }

    if (lowerMsg.includes("moderation") ||
        lowerMsg.includes("sensitive") ||
        lowerMsg.includes("inappropriate") ||
        lowerMsg.includes("prohibited")) {
      return {
        short: "Контент не прошёл модерацию",
        full: "Текст или описание содержит запрещённые слова. Измените содержимое и попробуйте снова."
      };
    }

    if (lowerMsg.includes("couldn't verify your audio") ||
        lowerMsg.includes("could not verify your audio") ||
        lowerMsg.includes("verify your audio")) {
      return {
        short: "Suno не смог проверить аудио",
        full: "Suno не смог проверить загруженный аудиореференс. Попробуйте загрузить другой файл или предварительно экспортировать его заново в MP3/WAV."
      };
    }

    if (lowerMsg.includes("can't parse uploaded audio") ||
        lowerMsg.includes("cannot parse uploaded audio") ||
        lowerMsg.includes("source is corrupted") ||
        lowerMsg.includes("corrupted")) {
      return {
        short: "Suno не смог прочитать аудиофайл",
        full: "Suno считает загруженный аудиофайл повреждённым или неподдерживаемым. Экспортируйте файл заново в MP3/WAV и повторите генерацию."
      };
    }

    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Для V5/V5.5 лимиты Suno: до 5000 символов lyrics/prompt и до 1000 символов style."
      };
    }

    if (lowerMsg.includes("credit") || lowerMsg.includes("balance") || lowerMsg.includes("insufficient")) {
      return {
        short: "Недостаточно кредитов Suno",
        full: "На аккаунте Suno недостаточно кредитов для генерации. Обратитесь в поддержку."
      };
    }
  }

  const errorMessages: Record<number, { short: string; full: string }> = {
    400: { short: "Неверные параметры запроса", full: "Проверьте введённые данные и попробуйте снова." },
    401: { short: "Ошибка авторизации", full: "Проблема с авторизацией в сервисе Suno. Обратитесь в поддержку." },
    403: { short: "Контент заблокирован", full: "Запрос содержит запрещённый контент. Измените текст или описание." },
    404: { short: "Ресурс не найден", full: "Запрашиваемый ресурс не найден. Попробуйте ещё раз." },
    405: { short: "Превышена частота запросов", full: "Слишком много запросов. Подождите несколько минут." },
    413: {
      short: "Suno отклонил запрос",
      full: originalMessage
        ? `Suno отклонил запрос: ${originalMessage}`
        : "Suno отклонил запрос с кодом 413. Проверьте текст, стиль и аудиореференс."
    },
    429: { short: "Недостаточно кредитов", full: "На аккаунте Suno недостаточно кредитов. Обратитесь в поддержку." },
    455: { short: "Сервис на обслуживании", full: "Suno проходит техническое обслуживание. Попробуйте позже." },
    500: { short: "Ошибка сервера Suno", full: "Внутренняя ошибка на сервере Suno. Попробуйте позже." },
    503: { short: "Сервис недоступен", full: "Suno временно перегружен. Попробуйте позже." }
  };

  if (errorMessages[code]) {
    return errorMessages[code];
  }

  return {
    short: `Ошибка генерации (код ${code})`,
    full: originalMessage || `Произошла ошибка при генерации. Код: ${code}`
  };
}
