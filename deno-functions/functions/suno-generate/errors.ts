export function getSunoErrorMessage(code: number, originalMessage?: string): { short: string; full: string } {
  if (originalMessage) {
    const lowerMsg = originalMessage.toLowerCase();

    if (lowerMsg.includes("matches existing work") ||
        lowerMsg.includes("existing work of art") ||
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

    if (lowerMsg.includes("too long") || lowerMsg.includes("too large") || lowerMsg.includes("exceeds")) {
      return {
        short: "Превышен лимит символов",
        full: "Описание, стиль или текст песни слишком длинные. Сократите текст и попробуйте снова."
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
    413: { short: "Превышен лимит символов", full: "Текст слишком длинный (макс. ~5000 символов для lyrics, 1000 для style). Сократите и попробуйте снова." },
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
