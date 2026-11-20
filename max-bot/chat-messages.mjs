// Дизайн-система чата: лейблы кнопок, иконки, формат сообщений, тексты ошибок.
export const labels = {
  music: "🎵 Музыка",
  lyrics: "✍️ Тексты",
  image: "🖼️ Картинки",
  works: "📚 Мои работы",
  balance: "💰 Баланс",
  profile: "👤 Профиль",
  menu: "🏠 Меню",
  cancel: "✖️ Отмена",
  create: "🚀 Создать",
  topUp: "➕ Пополнить",
  worksMusic: "🎧 Мои треки",
  worksLyrics: "📝 Мои тексты",
  worksImage: "🌆 Мои картинки",
  songFromLyrics: "🎧 Сгенерировать трек",
  help: "❓ Помощь",
  back: "⬅️ Назад",
  pop: "🎧 Поп",
  rap: "🎤 Рэп",
  indie: "🌿 Инди",
  rock: "🎸 Рок",
  rnb: "💜 R&B",
  lofi: "☕ Lo-Fi",
  chanson: "🎼 Шансон",
  jazz: "🎷 Джаз",
  electro: "✨ Электро",
  ownStyle: "🎛 Свой стиль",
  autoStyle: "🤖 Авто-стиль",
  vocalF: "👩 Женский вокал",
  vocalM: "👨 Мужской вокал",
  vocalAny: "🎤 Без разницы",
  muteInfo: "🔕 Не напоминать",
  unmuteInfo: "🔔 Напоминать про сайт",
  link: "🔗 Подключить сайт",
  prev: "⬅️",
  next: "➡️",
};

// Обычные слова без эмодзи — чтобы работать и с кнопками, и с вводом руками.
const synonyms = {
  "Музыка": "music",
  "Тексты": "lyrics",
  "Картинки": "image",
  "Мои работы": "works",
  "Баланс": "balance",
  "Профиль": "profile",
  "Меню": "menu",
  "Отмена": "cancel",
  "Создать": "create",
  "Пополнить": "topUp",
  "Мои треки": "worksMusic",
  "Мои тексты": "worksLyrics",
  "Мои картинки": "worksImage",
  "Песня из текста": "songFromLyrics",
  "Сгенерировать трек": "songFromLyrics",
  "Помощь": "help",
  "Назад": "back",
  "Поп": "pop",
  "Рэп": "rap",
  "Инди": "indie",
  "Рок": "rock",
  "R&B": "rnb",
  "Lo-Fi": "lofi",
  "Шансон": "chanson",
  "Джаз": "jazz",
  "Электро": "electro",
  "Свой стиль": "ownStyle",
  "Авто-стиль": "autoStyle",
  "Женский вокал": "vocalF",
  "Мужской вокал": "vocalM",
  "Без разницы": "vocalAny",
  "Не напоминать": "muteInfo",
  "Напоминать про сайт": "unmuteInfo",
  "Подключить сайт": "link",
  "Привязать AIMUZA": "link",
  "Предыдущая": "prev",
  "Следующая": "next",
};

// action: входящий текст → каноническое имя действия.
export const action = Object.fromEntries([
  ...Object.entries(labels).map(([key, label]) => [label, key]),
  ...Object.entries(synonyms),
]);

// Главное меню — вертикальный стек на всю ширину, как в лучших ботах.
export const menu = [
  [labels.music],
  [labels.lyrics],
  [labels.image],
  [labels.works],
  [labels.balance],
  [labels.profile],
  [labels.help],
];

// Сетка жанров и вокала для мастера создания трека.
export const genreRows = [
  [labels.pop, labels.rap, labels.indie],
  [labels.rock, labels.rnb, labels.lofi],
  [labels.chanson, labels.jazz, labels.electro],
  [labels.ownStyle, labels.autoStyle],
];
export const vocalRows = [[labels.vocalF, labels.vocalM], [labels.vocalAny], [labels.back]];

export const rubles = value => new Intl.NumberFormat("ru-RU").format(value) + " ₽";
export const profileLabel = mode => mode === "site" ? "Аккаунт сайта" : "Только в MAX";
export const linkButton = (text, url) => ({ type: "link", text, url });

const kindIcons = { music: "🎧", lyrics: "📝", image: "🖼️" };
const kindTitles = { music: "Мои треки", lyrics: "Мои тексты", image: "Мои картинки" };
export const itemIcon = kind => kindIcons[kind] ?? "📎";
export const kindTitle = kind => kindTitles[kind] ?? "Мои работы";
export const statusIcon = status => ({ completed: "✅", pending: "⏳", processing: "⏳", failed: "❌" })[status] ?? "•";

export const title = value => {
  const clean = String(value || "Без названия").replace(/[\r\n]+/g, " ").trim();
  return clean.length > 60 ? `${clean.slice(0, 60).trimEnd()}…` : clean;
};

// Пользовательский текст в markdown-сообщении — цитатой, чтобы не ломал разметку.
export const quote = text => String(text).split("\n").map(line => `> ${line.slice(0, 200)}`).join("\n");

export function keyboard(rows) {
  return {
    type: "inline_keyboard",
    payload: { buttons: rows.map(row => row.map(item => typeof item === "string" ? { type: "message", text: item } : item)) },
  };
}

// markdown: true — только для сообщений, где весь текст наш; чужой текст экранируется цитатой.
export function message(text, rows = [], markdown = false) {
  return {
    text,
    ...(markdown ? { format: "markdown" } : {}),
    ...(rows.length ? { attachments: [keyboard(rows)] } : {}),
  };
}

const errorTexts = {
  INSUFFICIENT_FUNDS: "😢 Недостаточно средств. Пополнить можно в разделе «Баланс».",
  INSUFFICIENT_BALANCE: "😢 Недостаточно средств. Пополнить можно в разделе «Баланс».",
  PRICE_CHANGED: "🔄 Цена изменилась. Выбери генератор ещё раз и подтверди новую стоимость.",
  PROFILE_CHANGED: "👤 Профиль недоступен. Проверь выбранный аккаунт в разделе «Профиль».",
  GENERATION_PENDING: "⏳ Картинка уже создаётся — подожди её завершения.",
  UNAVAILABLE: "🛠 Генератор временно недоступен. Попробуй позже.",
  GENERATION_FAILED: "😔 Генерация не завершилась. Проверь статус в «Моих работах».",
  BAD_AMOUNT: "🔢 Сумма — от 10 до 150 000 ₽ целым числом. Попробуй ещё раз.",
  NOT_FOUND: "🔍 Работа недоступна. Обнови список в «Моих работах».",
};

const errorRows = {
  INSUFFICIENT_FUNDS: () => [[labels.topUp], [labels.menu]],
  INSUFFICIENT_BALANCE: () => [[labels.topUp], [labels.menu]],
  PROFILE_CHANGED: () => [[labels.profile], [labels.menu]],
  GENERATION_FAILED: () => [[labels.works, labels.menu]],
  NOT_FOUND: () => [[labels.works, labels.menu]],
  BAD_AMOUNT: () => [[labels.cancel]],
};

export function presentError(error) {
  return errorTexts[error.message] ?? "⚠️ Не удалось выполнить действие. Попробуй ещё раз.";
}

export function errorButtons(error) {
  return (errorRows[error.message] ?? (() => [[labels.menu]]))();
}

export async function sendLyrics(send, lyric, rows) {
  const head = lyric.title ? `📝 «${title(lyric.title)}»` : "📝 Текст песни";
  let remaining = [head, lyric.lyrics].filter(Boolean).join("\n\n").trim();
  while (remaining.length > 3000) {
    const lastLine = remaining.lastIndexOf("\n", 3000);
    let end = lastLine > 1500 ? lastLine + 1 : 3000;
    if (/[\uD800-\uDBFF]/.test(remaining[end - 1])) end--;
    await send(message(remaining.slice(0, end)));
    remaining = remaining.slice(end);
  }
  await send(message(remaining, rows));
}
