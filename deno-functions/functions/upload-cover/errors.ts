export function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();

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
        short: "AIMUZA не смогла проверить аудио",
        full: "AIMUZA не смогла проверить загруженный аудиореференс. Попробуйте загрузить другой файл или предварительно экспортировать его заново в MP3/WAV."
      };
    }

    if (lowerMsg.includes("can't parse uploaded audio") ||
        lowerMsg.includes("cannot parse uploaded audio") ||
        lowerMsg.includes("source is corrupted") ||
        lowerMsg.includes("corrupted")) {
      return {
        short: "AIMUZA не смогла прочитать аудиофайл",
        full: "AIMUZA считает загруженный аудиофайл повреждённым или неподдерживаемым. Экспортируйте файл заново в MP3/WAV и повторите генерацию."
      };
    }

    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Для генерации по аудиореференсу в V5/V5.5 лимиты AIMUZA: до 5000 символов текста и до 1000 символов стиля."
      };
    }

    if (lowerMsg.includes("credit") || lowerMsg.includes("balance") || lowerMsg.includes("insufficient")) {
      return {
        short: "Генерация временно недоступна",
        full: "Генерация AIMUZA временно недоступна. Обратитесь в поддержку."
      };
    }
  }

  const errorMessages: Record<number, { short: string; full: string }> = {
    400: { short: "Неверные параметры запроса", full: "Проверьте введённые данные и попробуйте снова." },
    401: { short: "Ошибка авторизации", full: "Проблема с авторизацией в сервисе AIMUZA. Обратитесь в поддержку." },
    403: { short: "Контент заблокирован", full: "Запрос содержит запрещённый контент. Измените текст или описание." },
    404: { short: "Ресурс не найден", full: "Запрашиваемый ресурс не найден. Попробуйте ещё раз." },
    405: { short: "Превышена частота запросов", full: "Слишком много запросов. Подождите несколько минут." },
    413: {
      short: "AIMUZA отклонила запрос",
      full: originalMessage
        ? `AIMUZA отклонила запрос: ${originalMessage.replace(/suno/gi, "AIMUZA")}`
        : "AIMUZA отклонила генерацию по аудиореференсу с кодом 413. Этот код может означать не только лимит текста, но и проблему с аудиофайлом или проверкой контента."
    },
    429: { short: "Генерация временно недоступна", full: "Генерация AIMUZA временно недоступна. Обратитесь в поддержку." },
    455: { short: "Сервис на обслуживании", full: "AIMUZA проходит техническое обслуживание. Попробуйте позже." },
    500: { short: "Внутренняя ошибка сервера", full: "Внутренняя ошибка на сервере AIMUZA. Попробуйте позже." },
    503: { short: "Сервис недоступен", full: "AIMUZA временно перегружена. Попробуйте позже." }
  };

  if (errorMessages[code]) {
    return errorMessages[code];
  }

  return {
    short: `Ошибка генерации (код ${code})`,
    full: originalMessage?.replace(/suno/gi, "AIMUZA") || `Произошла ошибка при генерации. Код: ${code}`
  };
}
