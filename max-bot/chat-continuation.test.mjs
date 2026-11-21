import assert from "node:assert/strict";
import { once } from "node:events";
import { test } from "node:test";
import { createChatHandler } from "./chat.mjs";
import { startChatWorkers } from "./chat-jobs.mjs";
import { createChatStore } from "./chat-store.mjs";
import { createWebhookServer } from "./webhook.mjs";
import { imageActions } from "./chat-images.mjs";
import { labels } from "./chat-messages.mjs";

const ownerId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const imageId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const button = imageActions(imageId, ownerId).attachments[0].payload.buttons[0][0];

test("a lyrics-to-music order resumes from the same request after checkout and balance navigation", { timeout: 7000 }, async t => {
  const store = createChatStore(":memory:");
  const rejected = Promise.withResolvers();
  const accepted = Promise.withResolvers();
  const starts = [];
  let balance = 0;
  const max = { async send(_event, body) { if (body.text.includes("сохранён на сутки")) rejected.resolve(body); } };
  const api = async (action, _event, body) => {
    if (action === "profile") return { ownerId, music: 28, mode: "max", balance };
    if (action === "payment") {
      assert.equal(body.ownerId, ownerId);
      return { url: "https://auth.robokassa.ru/Merchant/Index.aspx" };
    }
    if (action === "start") {
      starts.push(body);
      if (balance < body.price) throw Object.assign(new Error("INSUFFICIENT_FUNDS"), { status: 402 });
      accepted.resolve();
      return { accepted: true };
    }
    assert.fail(`Unexpected action ${action}`);
  };
  const handle = createChatHandler({ store, api, max });
  const stop = startChatWorkers({ store, api, max, handle });
  t.after(() => { stop(); store.close(); });
  let key = 0;
  const send = text => handle({ text, key: String(++key), userId: 25, chatId: 40 });
  store.setLastLyrics(25, { ownerId, lyricsId: "saved-lyric" });
  await send(labels.songFromLyrics);
  await send(labels.pop);
  await send(labels.vocalF);
  await send(labels.create);
  const notice = await rejected.promise;
  assert.equal(notice.attachments[0].payload.buttons[0][0].text, labels.topUpOrder);
  await send(labels.topUpOrder);
  await send("50");
  await send(labels.balance);
  balance = 50;
  await send(labels.songFromLyrics);
  await accepted.promise;
  assert.equal(starts.length, 2);
  assert.deepEqual(starts[1], starts[0]);
  assert.equal(starts[1].lyricsId, "saved-lyric");
  assert.match(starts[1].prompt, /поп, женский вокал/);
  assert.equal(store.pendingOrder(25), null);
});

test("image generation stores a reference and revision targets the image on the pressed button", async t => {
  const store = createChatStore(":memory:");
  t.after(store.close);
  const sent = [];
  const handle = createChatHandler({
    store,
    max: {
      send: async (_event, body) => sent.push(body),
      downloadPhoto: async () => ({ bytes: new Uint8Array([1, 2, 3]), type: "image/jpeg" }),
    },
    api: async (action, _event, body) => {
      if (action === "image-source") {
        assert.deepEqual(body, { ownerId, id: imageId });
        return { price: 5, mode: "max" };
      }
      assert.equal(action, "profile");
      return { ownerId, mode: "max", image: 5 };
    },
  });
  let key = 0;
  const send = (text, extra) => handle({ userId: 25, text, key: String(++key), ...extra });
  await send(labels.image);
  await send("Оранжевая обложка");
  await send("", { photo: { mid: "photo-without-caption" } });
  assert.match(sent.at(-1).text, /Проверь заказ/);
  await send(labels.create);
  const first = store.nextJob();
  assert.equal(first.prompt, "Оранжевая обложка");
  assert.equal(store.reference(25, first.referenceId).size, 3);
  assert.equal(store.reference(26, first.referenceId), undefined);
  store.finishJob(first.id);

  await send(labels.image);
  await send("", { photo: { mid: "reference-first" } });
  assert.match(sent.at(-1).text, /Референс принят/);
  await send("Космос и звёзды");
  assert.match(sent.at(-1).text, /Референс прикреплён/);
  await send(labels.create);
  store.finishJob(store.nextJob().id);

  await send("", { callback: button.payload });
  assert.match(sent.at(-1).text, /Что изменить/);
  await send("Убери слово ВЕСНА");
  await send(labels.create);
  assert.equal(store.nextJob().imageId, imageId);
  assert.equal(store.nextJob().prompt, "Убери слово ВЕСНА");
});

test("webhook accepts captionless photos and image callbacks from a private dialog", async t => {
  const events = [];
  const server = createWebhookServer({ secret: "test-secret", enqueue: event => events.push(event) });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise(resolve => server.close(resolve)));
  const send = body => fetch(`http://127.0.0.1:${server.address().port}/webhooks/max`, {
    method: "POST", body: JSON.stringify(body), headers: { "X-Max-Bot-Api-Secret": "test-secret" },
  });
  const recipient = { chat_type: "dialog", chat_id: 40 };
  const url = "https://i.oneme.ru/photo";
  assert.equal((await send({ update_type: "message_created", message: {
    recipient, sender: { user_id: 25 }, body: { mid: "photo", text: null, attachments: [{ type: "image", payload: { url } }] },
  } })).status, 200);
  assert.equal((await send({ update_type: "message_callback", message: { recipient }, callback: {
    user: { user_id: 25 }, callback_id: "tap", payload: button.payload,
  } })).status, 200);
  assert.deepEqual(events[0].photo, { mid: "photo", url });
  assert.equal(events[1].callback, button.payload);
  recipient.chat_type = "chat";
  assert.equal((await send({ update_type: "message_callback", message: { recipient }, callback: {
    user: { user_id: 25 }, callback_id: "tap-group", payload: button.payload,
  } })).status, 200);
  assert.equal(events.length, 2);
});
