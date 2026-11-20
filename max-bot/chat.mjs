import { randomUUID } from "node:crypto";
import {
  action, errorButtons, genreRows, itemIcon, kindTitle, labels, linkButton, menu, message,
  presentError, profileLabel, quote, rubles, sendLyrics, statusIcon, title, vocalRows,
} from "./chat-messages.mjs";

const promptHints = {
  lyrics: "Расскажи, о ком или о чём песня, до 200 символов. Например: «Песня о ветре и дороге домой».",
  image: "Опиши, какую картинку создать, до 1000 символов. Например: «Ночной город в неоновых огнях».",
};
const library = { worksMusic: "music", worksLyrics: "lyrics", worksImage: "image" };
const itemNames = { music: "Трек", lyrics: "Текст", image: "Картинка" };
const genreStyles = {
  pop: "поп", rap: "рэп", indie: "инди", rock: "рок", rnb: "R&B",
  lofi: "lo-fi", chanson: "шансон", jazz: "джаз", electro: "электронная музыка",
};
const vocalStyles = { vocalF: "женский вокал", vocalM: "мужской вокал" };
const eta = {
  music: "Обе версии трека обычно готовы за несколько минут",
  lyrics: "Текст обычно готов за минуту",
  image: "Картинка обычно готова за минуту-две",
};

export function createChatHandler({ store, api, max, siteUrl }) {
  return async event => {
    const text = event.text?.trim() ?? "";
    const btn = action[text] ?? (text.startsWith(labels.balance) ? "balance" : text);
    const send = body => max.send(event, body);
    const reply = (body, rows = menu) => send(message(body, rows));
    const md = (body, rows) => send(message(body, rows, true));
    const state = store.state(event.userId);
    const save = value => store.setState(event.userId, value);
    const call = (name, body) => api(name, event, body);

    const menuRows = balance => [
      [labels.music], [labels.lyrics], [labels.image], [labels.works],
      [`${labels.balance} · ${rubles(balance)}`], [labels.profile], [labels.help],
    ];

    async function mainScreen() {
      const profile = await call("profile");
      return reply("🎨 Чем займёмся?", menuRows(profile.balance));
    }

    // Шаг мастера: выбор жанра для трека (свой промт тоже доступен).
    const trackScreen = (lyricsId, price) => md(`# 🎧 Трек · ${rubles(price)}\n\nЗа эту цену — **две версии** трека.\n\n${lyricsId
      ? "Текст готов! Теперь выбери жанр — или опиши звучание своими словами 👇"
      : "Опиши звучание своими словами — или выбери жанр 👇"}`, [...genreRows, [labels.back]]);

    const vocalScreen = state =>
      md(`🎧 Жанр: ${title(state.genreLabel)} · ${rubles(state.price)}\n\nВыбери тип вокала 👇`, vocalRows);

    const confirmCard = s => {
      const brief = s.prompt.length > 400 ? `${s.prompt.slice(0, 400).trimEnd()}…` : s.prompt;
      const versions = s.kind === "music" ? "\n💿 В цену входят две версии трека" : "";
      return md(`✅ Проверь заказ\n\n${quote(brief)}\n\n💰 ${rubles(s.price)} · профиль «${profileLabel(s.profileMode)}»${versions}\n\nСоздаём?`, [
        [labels.create, labels.cancel],
      ]);
    };

    async function profileMenu() {
      const profile = await call("profile");
      const hint = profile.mode === "site"
        ? "Библиотека и баланс общие с сайтом aimuza.ru."
        : profile.siteLinked
          ? "Можно переключиться на аккаунт сайта — там общие библиотека и баланс с aimuza.ru."
          : "Привяжи аккаунт сайта, чтобы пользоваться общими работами и балансом на aimuza.ru.";
      const choices = profile.mode === "site" ? [["Только в MAX"]]
        : [[profile.siteLinked ? "Аккаунт сайта" : labels.link]];
      return md(`# 👤 Профиль\n\nВыбран «${profileLabel(profile.mode)}» · баланс ${rubles(profile.balance)}.\n\n${hint}`, [
        ...choices, [labels.menu],
      ]);
    }

    async function works(kind, page, ownerId) {
      const result = await call("works", { ownerId, kind, page });
      const entries = result.items.map((item, i) => ({ ...item, button: String(i + 1) }));
      save({ mode: "works", entries, kind, page, ownerId, more: result.more });
      const ready = entries.filter(item => item.ready).map(item => item.button);
      const list = entries.map((item, i) => `${statusIcon(item.status)} ${i + 1} · ${title(item.title)}`).join("\n");
      const paging = [...(page > 0 ? [labels.prev] : []), ...(result.more ? [labels.next] : [])];
      const suffix = page > 0 || result.more ? ` · страница ${page + 1}` : "";
      return reply(list
        ? `${itemIcon(kind)} ${kindTitle(kind)}${suffix}\n\n${list}`
        : `${itemIcon(kind)} ${kindTitle(kind)}\n\nПока пусто — всё, что ты создашь, появится здесь.`, [
        ...(ready.length ? [ready] : []),
        ...(paging.length ? [paging] : []),
        [labels.works, labels.menu],
      ]);
    }

    try {
      if (/^\/help(\s|$)/i.test(text) || btn === "help") {
        save({});
        return md([
          "# 📖 Шпаргалка AIMUZA",
          "",
          "**Создание**",
          `${labels.music} — трек: опиши звучание или выбери жанр и вокал (в цену входят две версии)`,
          `${labels.lyrics} — текст песни по теме (до 200 символов)`,
          `${labels.image} — картинка по описанию (до 1000 символов)`,
          "",
          "**Работы и баланс**",
          `${labels.works} — треки, тексты и картинки выбранного профиля`,
          `${labels.balance} — остаток и пополнение от 10 до 150 000 ₽`,
          `${labels.profile} — «Только в MAX» или аккаунт сайта`,
          "",
          "**Ещё**",
          `${labels.songFromLyrics} — трек из сохранённого текста`,
          "Команды: /start — меню · /unlink — отвязать сайт",
        ].join("\n"), menu);
      }
      if (!text || /^\/start(\s|$)/i.test(text) || btn === "menu" || btn === "cancel") {
        const fresh = Object.keys(state).length === 0 && (!text || /^\/start(\s|$)/i.test(text));
        save({});
        const profile = await call("profile");
        if (fresh) {
          return md(`# 🎵 AIMUZA\n\nМузыка, тексты песен и картинки по описанию. Опишешь идею — подскажу цену и поставлю в работу.\n\nСейчас выбран профиль «${profileLabel(profile.mode)}»`, menuRows(profile.balance));
        }
        return mainScreen();
      }
      if (btn === "profile") {
        save({});
        return profileMenu();
      }
      if (/^\/unlink(\s|$)/i.test(text)) {
        await call("unlink");
        save({});
        return md("✅ Связь с сайтом снята. Выбран профиль «Только в MAX».");
      }
      if (text === "Только в MAX" || text === "Аккаунт сайта") {
        const mode = text === "Только в MAX" ? "max" : "site";
        await call("switch", { mode });
        save({});
        return md(`✅ Выбран профиль «${profileLabel(mode)}».`);
      }
      if (btn === "link") {
        const { link, signupCode } = await call("link");
        const url = new URL("/m/max-link", siteUrl);
        if (signupCode) url.searchParams.set("signup", "1");
        url.hash = link;
        save({ mode: "link" });
        const signup = signupCode
          ? "\n\nНет аккаунта сайта? Выбери «Создать аккаунт» на странице и введи код регистрации: " +
            `${signupCode}. Работы и баланс MAX сохранятся.`
          : "";
        return md(`# 🔗 Подключение сайта\n\n1. Открой AIMUZA по кнопке и войди в аккаунт\n2. Нажми «Получить код» на странице привязки\n3. Пришли сюда 8-значный код со страницы${signup}`, [
          [linkButton("🔗 Открыть AIMUZA", url.href)], [labels.cancel],
        ]);
      }
      if (state.mode === "link" && /^[0-9]{8}$/.test(text)) {
        const { linked } = await call("verify", { code: text });
        if (linked) save({});
        return linked
          ? md("✅ Сайт подключён — выбран «Аккаунт сайта». Баланс и библиотека теперь общие с aimuza.ru, а профиль MAX доступен в разделе «Профиль».")
          : reply("❌ Код не подошёл или связь уже занята. Проверь код либо запроси новую ссылку.", [[labels.link, labels.cancel]]);
      }

      if (btn === "songFromLyrics") {
        const last = store.lastLyrics(event.userId);
        if (!last?.lyricsId) {
          return reply("🎧 Сначала выбери текст в «Мои тексты» — из него соберу трек.", [[labels.worksLyrics, labels.menu]]);
        }
        const profile = await call("profile", { ownerId: last.ownerId });
        const price = profile.music;
        if (!Number.isSafeInteger(price) || price < 1) return reply("🛠 Генератор временно недоступен. Попробуй позже.");
        save({ mode: "prompt", kind: "music", price, ownerId: profile.ownerId, profileMode: profile.mode, lyricsId: last.lyricsId });
        return trackScreen(last.lyricsId, price);
      }
      if (btn === "music" || btn === "lyrics" || btn === "image") {
        const profile = await call("profile");
        const price = profile[btn];
        if (!Number.isSafeInteger(price) || price < 1) return reply("🛠 Генератор временно недоступен. Попробуй позже.");
        save({ mode: "prompt", kind: btn, price, ownerId: profile.ownerId, profileMode: profile.mode });
        if (btn === "music") return trackScreen(undefined, price);
        return md(`# ${itemIcon(btn)} ${itemNames[btn]} · ${rubles(price)}\n\n${promptHints[btn]}`, [[labels.cancel]]);
      }
      if (btn === "balance" || btn === "topUp") {
        const profile = await call("profile");
        const label = profileLabel(profile.mode);
        if (btn === "balance") {
          save({});
          return md(`# 💰 Баланс\n\nПрофиль «${label}» — ${rubles(profile.balance)}.\n\nПополнение от 10 до 150 000 ₽ целым числом. Деньги приходят после подтверждения Робокассой.`, [
            [labels.topUp], ...menu,
          ]);
        }
        save({ mode: "payment", ownerId: profile.ownerId, profileMode: profile.mode });
        return md(`# ➕ Пополнение\n\nПрофиль «${label}». Введи сумму от 10 до 150 000 ₽ целым числом.`, [[labels.cancel]]);
      }
      if (btn === "works") {
        save({});
        return reply("Что показать?", [Object.keys(library).map(key => labels[key]), [labels.menu]]);
      }
      if (library[btn]) {
        const { ownerId } = await call("profile");
        return await works(library[btn], 0, ownerId);
      }
      if (state.mode === "works") {
        if (btn === "prev" && state.page > 0) return await works(state.kind, state.page - 1, state.ownerId);
        if (btn === "next" && state.more) return await works(state.kind, state.page + 1, state.ownerId);
        const item = state.entries.find(entry => entry.button === text && entry.ready);
        if (item && state.kind === "lyrics") {
          const lyric = await call("lyric", { id: item.id, ownerId: state.ownerId });
          store.setLastLyrics(event.userId, { lyricsId: item.id, ownerId: state.ownerId });
          return await sendLyrics(send, lyric, [[labels.songFromLyrics], [labels.worksLyrics, labels.menu]]);
        }
        if (item) {
          store.addJob({ id: randomUUID(), event, ownerId: state.ownerId, kind: state.kind ?? item.kind, phase: "deliver", items: [item] });
          return reply("📤 Отправляю файл…", [[labels.menu]]);
        }
      }

      if (state.mode === "payment" || (state.mode === "checkout" && state.eventKey === event.key)) {
        const amount = /^\d{2,6}$/.test(text) ? Number(text) : 0;
        if (amount < 10 || amount > 150000) return reply("🔢 Введи сумму от 10 до 150 000 ₽ целым числом.", [[labels.cancel]]);
        const payment = state.mode === "checkout" ? state : await call("payment", { amount, ownerId: state.ownerId });
        save({ ...state, mode: "checkout", url: payment.url, eventKey: event.key });
        return md(`💳 Счёт на ${rubles(amount)} для «${profileLabel(state.profileMode)}» создан.\n\nБаланс обновится после подтверждения Робокассой.`, [
          [linkButton("💳 Открыть оплату", payment.url)], [labels.balance],
        ]);
      }
      if (btn === "create" && (state.mode === "confirm" || (state.mode === "queued" && state.eventKey === event.key))) {
        store.addJob({
          id: state.id, event, ownerId: state.ownerId, kind: state.kind, lyricsId: state.lyricsId,
          prompt: state.prompt, price: state.price, phase: "start",
        });
        save({ ...state, mode: "queued", eventKey: event.key });
        return md(`⏳ Задание принято в работу.\n\n${eta[state.kind] ?? "Обычно это занимает несколько минут"} — пришлю результат сюда.`, [
          [labels.works, labels.menu],
        ]);
      }
      if (state.mode === "prompt") {
        if (btn === "back") {
          save({});
          return mainScreen();
        }
        if (state.kind === "music") {
          if (btn === "autoStyle" || genreStyles[btn]) {
            const genre = btn === "autoStyle" ? "любой подходящий стиль" : genreStyles[btn];
            const genreLabel = btn === "autoStyle" ? labels.autoStyle : labels[btn];
            save({ ...state, mode: "vocal", genre, genreLabel });
            return vocalScreen({ ...state, genreLabel });
          }
          if (btn === "ownStyle") {
            save({ ...state, mode: "styleInput" });
            return md("🎛 Свой стиль\n\nОпиши звучание своими словами — темп, инструменты, настроение. Например: «мягкий инди-поп с гитарой и тёплым вокалом».", [
              [labels.back],
            ]);
          }
        }
        const limit = state.kind === "lyrics" ? 200 : 1000;
        if (text.length > limit) return reply(`✂️ Сократи описание до ${limit} символов — сейчас ${text.length}.`, [[labels.cancel]]);
        save({ ...state, mode: "confirm", id: randomUUID(), prompt: text });
        return confirmCard({ ...state, prompt: text });
      }
      if (state.mode === "styleInput") {
        if (btn === "back") return trackScreen(state.lyricsId, state.price);
        if (text.length > 300) return reply(`✂️ Сократи описание стиля до 300 символов — сейчас ${text.length}.`, [[labels.cancel]]);
        save({ ...state, mode: "vocal", genre: text, genreLabel: title(text) });
        return vocalScreen({ ...state, genreLabel: title(text) });
      }
      if (state.mode === "vocal") {
        if (btn === "back") {
          save({ ...state, mode: "prompt", genre: undefined, genreLabel: undefined });
          return trackScreen(state.lyricsId, state.price);
        }
        if (btn === "vocalAny" || vocalStyles[btn]) {
          const prompt = [state.genre, vocalStyles[btn]].filter(Boolean).join(", ");
          save({ ...state, mode: "confirm", id: randomUUID(), prompt });
          return confirmCard({ ...state, prompt });
        }
        return vocalScreen(state);
      }
      return reply("🤔 Не понял. Выбери действие в меню.");
    } catch (error) {
      if (error.message === "LINK_REQUIRED") return reply("🔗 Подключи аккаунт сайта по новой ссылке.", [[labels.link, "Только в MAX"]]);
      if (error.status >= 400 && error.status < 500) return reply(presentError(error), errorButtons(error));
      throw error;
    }
  };
}
