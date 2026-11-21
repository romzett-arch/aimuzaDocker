import { randomUUID } from "node:crypto";
import { labels, message } from "./chat-messages.mjs";

const idPattern = "[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}";
export const editImagePattern = new RegExp(`^image:edit:(${idPattern}):(${idPattern})$`);

export function imageActions(id, ownerId) {
  return message("Хочешь что-то изменить?", [[{
    type: "callback", text: "🔄 Перегенерировать", payload: `image:edit:${ownerId}:${id}`,
  }], [labels.worksImage, labels.menu]]);
}

export async function handleImageStep({ event, state, save, call, max, store, reply, confirmCard, btn, text }) {
  const edit = event.callback?.match(editImagePattern);
  if (edit) {
    const [, ownerId, imageId] = edit;
    const source = await call("image-source", { ownerId, id: imageId });
    if (!Number.isSafeInteger(source.price) || source.price < 1) return reply("🛠 Генератор временно недоступен. Попробуй позже.");
    save({ mode: "imageEdit", kind: "image", ownerId, profileMode: source.mode, price: source.price, imageId });
    return reply("Что изменить? Например: «Убери слово ВЕСНА и добавь облака». Возьму за основу эту картинку. Можешь также прикрепить новый референс.", [[labels.cancel]]);
  }

  if (state.mode === "imageReference") {
    if (btn === "skipReference") {
      save({ ...state, mode: "confirm" });
      return confirmCard(state);
    }
    if (!event.photo) return reply("Прикрепи картинку для примера или нажми «Без референса».", [[labels.skipReference, labels.cancel]]);
  }

  const prompt = state.mode === "imageReference" ? state.prompt : text || state.prompt;
  if (prompt?.length > 1000) return reply("✂️ Сократи описание до 1000 символов.", [[labels.cancel]]);
  let referenceId = state.referenceId;
  if (event.photo) {
    try {
      const reference = await max.downloadPhoto(event.photo);
      referenceId = randomUUID();
      store.saveReference(event.userId, referenceId, reference);
    } catch (error) {
      if (error.name === "TypeError" || error.name === "TimeoutError" || error.status >= 500) throw error;
      return reply("Не удалось открыть референс. Пришли фото в формате JPEG, PNG или WebP до 5 МБ.", state.mode === "imageEdit"
        ? [[labels.cancel]] : [[labels.skipReference, labels.cancel]]);
    }
  }
  if (!prompt) {
    save({ ...state, referenceId });
    return reply(state.mode === "imageEdit"
      ? "Референс принят. Напиши, что нужно изменить."
      : "Референс принят. Опиши, какую картинку создать.", [[labels.cancel]]);
  }

  const next = { ...state, id: state.id ?? randomUUID(), prompt, referenceId, mode: "confirm", eventKey: event.key };
  save(next);
  return confirmCard(next);
}
