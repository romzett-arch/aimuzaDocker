import { labels, linkButton } from "./chat-messages.mjs";

const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const codeRe = /^[A-Z0-9]{6}$/;
const codeHint = "✉️ Код подтверждения отправил на ";

// Мастер привязки аккаунта сайта — целиком в личном чате: почта → (пароль и
// никнейм, если аккаунта ещё нет) → код из письма. Один путь и для входа,
// и для регистрации: существующий аккаунт подтверждается кодом из письма.
export function createAuthStep({ state, save, call, reply, md, appUrl }) {
  const codeStep = (email, authMode, created) => {
    save({ mode: "linkCode", email, authMode, attempts: 0 });
    return md(`${codeHint}${email}. Перешли его сюда — и готово.${created ? "\n\nЕсли письма нет, проверь папку «Спам»." : ""}`);
  };

  return async ({ text }) => {
    if (state.mode === "linkEmail") {
      const email = String(text ?? "").toLowerCase().trim();
      if (!emailRe.test(email)) {
        return reply("📧 Это не похоже на почту. Пришли адрес одним сообщением — например name@example.com.", [[labels.cancel]]);
      }
      const result = await call("authEmail", { email });
      if (result.code === "EMAIL_IN_USE") {
        return reply("🔒 Эта почта занята подтверждённым аккаунтом. Пришли другую почту.", [[labels.cancel]]);
      }
      if (result.code === "ALREADY_LINKED") {
        save({});
        return md("🔒 Этот аккаунт сайта уже привязан к другому MAX. Отвяжи его там командой /unlink и попробуй снова.", [[labels.menu]]);
      }
      if (result.mode === "login") return codeStep(email, "login");
      if (result.resumed) return codeStep(email, "signup", true);
      save({ mode: "linkPassword", email, authMode: "signup" });
      return md([
        "🆕 Аккаунта с такой почтой нет — создадим прямо здесь.",
        "",
        "🔑 Придумай пароль для входа на сайт: минимум 8 символов, заглавная буква, цифра и спецсимвол.",
        "⚠️ Не используй пароль от почты — он останется в истории этого чата.",
      ].join("\n"), [[labels.cancel]]);
    }
    if (state.mode === "linkPassword") {
      const password = String(text ?? "").trim();
      if (password.length < 8 || password.length > 128) {
        return reply("🔑 Пароль — одним сообщением, минимум 8 символов. Заглавная буква, цифра и спецсимвол понадобятся тоже.", [[labels.cancel]]);
      }
      save({ ...state, mode: "linkNickname", password });
      return md("✍️ Как тебя звать на сайте? Никнейм — от 3 до 30 символов, его увидят другие музыканты.", [[labels.cancel]]);
    }
    if (state.mode === "linkNickname") {
      const username = String(text ?? "").trim();
      if (username.length < 3 || username.length > 30) {
        return reply("✍️ Никнейм — от 3 до 30 символов. Попробуй ещё раз.", [[labels.cancel]]);
      }
      const result = await call("authRegister", { email: state.email, password: state.password, username });
      if (result.code === "NICKNAME_TAKEN" || result.code === "BAD_NICKNAME") {
        return reply("😅 Такой никнейм уже занят или не подходит. Пришли другой.", [[labels.cancel]]);
      }
      if (result.code === "WEAK_PASSWORD") {
        save({ ...state, mode: "linkPassword", password: undefined });
        return md("🔑 Пароль не подошёл: нужен минимум 8 символов, заглавная буква, цифра и спецсимвол. Пришли другой пароль.");
      }
      if (result.code === "EMAIL_IN_USE") {
        save({ mode: "linkEmail", authMode: "signup" });
        return reply("🔒 Эту почту уже успели занять. Пришли другую почту.", [[labels.cancel]]);
      }
      return codeStep(state.email, "signup", true);
    }
    if (state.mode === "linkCode") {
      const code = String(text ?? "").toUpperCase().replace(/[\s-]/g, "");
      if (!codeRe.test(code)) {
        return reply("🔢 Код — 6 символов из письма, одним сообщением. Например: AB12CD.", [[labels.cancel]]);
      }
      const result = await call("authVerify", { email: state.email, code });
      if (result.ok) {
        const created = state.authMode === "signup";
        save({});
        return md(`# ✅ ${created ? "Аккаунт создан и привязан" : "Сайт подключён"}\n\nВыбран профиль «Аккаунт сайта»: работы и баланс теперь общие — в MAX, на сайте и в Студии. А треки можно выпускать на площадки (стриминги).`, [
          [linkButton("🚀 Открыть Студию", appUrl)],
          [labels.works, labels.menu],
        ]);
      }
      if (result.code === "ALREADY_LINKED") {
        save({});
        return md("🔒 Этот аккаунт уже привязан к другому MAX. Отвяжи его там командой /unlink и попробуй снова.", [[labels.menu]]);
      }
      const attempts = (state.attempts ?? 0) + 1;
      if (attempts >= 5) {
        save({});
        return reply("😞 Пять попыток подряд не прошли. Начни заново: 👤 Профиль → 🔗 Подключить сайт.", [[labels.profile]]);
      }
      save({ ...state, attempts });
      return reply("❌ Код не подошёл или устарел. Проверь письмо и пришли код ещё раз — попытка " + attempts + " из 5.", [[labels.cancel]]);
    }
    save({});
    return reply("🔗 Продолжим подключение? Пришли почту своего аккаунта AIMUZA.", [[labels.cancel]]);
  };
}
