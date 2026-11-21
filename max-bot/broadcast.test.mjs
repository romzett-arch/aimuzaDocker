import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { test } from "node:test";
import { createBroadcastService } from "./broadcast.mjs";
import { createChatStore } from "./chat-store.mjs";
import { createMaxClient } from "./max-api.mjs";
import { createWebhookServer } from "./webhook.mjs";

const owner = "00000000-0000-4000-8000-000000000001";
const id = "00000000-0000-4000-8000-000000000002";
const internalSecret = "test-internal-secret-32-characters";

async function listen(t, server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

test("broadcast sends once to selected groups, pins conditionally and reports partial results", async t => {
  const calls = [];
  const pins = new Map();
  const origin = await listen(t, createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost");
    const groupId = url.searchParams.get("chat_id") ?? url.pathname.split("/")[2];
    const endpoint = url.pathname.split("/").slice(3).join("/");
    const json = (body, status = 200) => res.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(body));
    assert.equal(req.headers.authorization, "fake-token");
    calls.push([req.method, groupId, endpoint]);
    if (req.method === "POST") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      assert.deepEqual(JSON.parse(Buffer.concat(chunks)), { text: "Анонс от АИМУЗА" });
      if (groupId === "-6") return json({ code: "uncertain" }, 503);
      if (groupId === "-2") pins.set(groupId, "other-pin");
      return json({ message: { body: { mid: `message-${groupId}` } } });
    }
    if (endpoint === "members/me") {
      const permissions = ["read_all_messages"];
      if (groupId !== "-5") permissions.push("write");
      if (groupId !== "-3") permissions.push("pin_message");
      return json({ is_admin: true, permissions });
    }
    if (endpoint === "pin" && req.method === "PUT") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks));
      assert.deepEqual(body, { message_id: `message-${groupId}`, notify: false });
      assert.equal(pins.has(groupId), false);
      pins.set(groupId, body.message_id);
      return json({ success: true });
    }
    if (endpoint === "pin") {
      if (groupId === "-4") return json({}, 503);
      return json({ message: pins.has(groupId) ? { body: { mid: pins.get(groupId) } } : null });
    }
    return json({ type: "chat", status: "active", title: `Группа ${groupId}` });
  }));

  const store = createChatStore(":memory:");
  t.after(store.close);
  const service = createBroadcastService({ store: store.broadcasts, max: createMaxClient("fake-token", origin) });
  const targets = ["-1", "-2", "-3", "-4", "-5", "-6", "-7", "-8"].map(id => ({ id, pin: id !== "-7" }));
  for (const { id: chatId } of targets.slice(0, -1)) {
    assert.equal((await service.admin({ owner, action: "broadcast-add-group", chatId }))[0], 200);
  }
  const request = { owner, action: "broadcast-send", id, text: "Анонс от АИМУЗА", targets };
  assert.equal((await service.admin(request))[0], 200);
  assert.equal((await service.admin({ ...request, includeBotLink: false }))[0], 200);
  assert.equal((await service.admin({ ...request, text: "Другой текст" }))[0], 409);
  for (const _target of targets) await service.processNext();
  const [, report] = await service.admin({ owner, action: "broadcast-status", id });
  assert.equal(report.done, true);
  assert.deepEqual(report.results.map(result => result.status), [
    "pinned", "pin_occupied", "pin_forbidden", "pin_failed", "send_forbidden", "send_unknown", "sent", "group_unavailable",
  ]);
  assert.equal((await service.admin(request))[1].done, true);
  await service.processNext();
  assert.deepEqual(calls.filter(([method]) => method === "POST").map(([, groupId]) => groupId),
    ["-1", "-2", "-3", "-4", "-6", "-7"]);
  assert.deepEqual(calls.filter(([method]) => method === "PUT").map(([, groupId]) => groupId), ["-1"]);
  assert.equal(pins.get("-2"), "other-pin");
  assert.equal((await service.admin({ action: "broadcast-status", id, owner: id }))[0], 404);
});

test("broadcast can attach a button to the bot's own MAX profile", async t => {
  const store = createChatStore(":memory:");
  t.after(store.close);
  const deliveries = [];
  let profileReads = 0;
  const max = {
    async chat() { return { type: "chat", status: "active" }; },
    async chatMembership() { return { is_admin: true, permissions: ["write"] }; },
    async me() {
      profileReads++;
      return { is_bot: true, username: "test_aimuza_bot" };
    },
    async send(target, body) {
      deliveries.push({ target, body });
      return { message: { body: { mid: "sent-message" } } };
    },
  };
  const service = createBroadcastService({ store: store.broadcasts, max });
  const targets = ["-1", "-2"].map(id => ({ id, pin: false }));
  for (const target of targets) store.broadcasts.group(target.id, null, true, Date.now());

  const input = { action: "broadcast-send", owner, id, text: "Давайте создадим песню!", targets, includeBotLink: true };
  assert.equal((await service.admin({ ...input, includeBotLink: "true" }))[0], 400);
  assert.equal((await service.admin(input))[0], 200);
  assert.equal((await service.admin({ ...input, includeBotLink: false }))[0], 409);
  await service.processNext();
  await service.processNext();
  assert.equal((await service.admin(input))[1].done, true);
  assert.equal(profileReads, 1);
  assert.deepEqual(deliveries, targets.map(({ id }) => ({
    target: { groupId: id },
    body: {
      text: input.text,
      attachments: [{ type: "inline_keyboard", payload: { buttons: [[{
        type: "link", text: "Открыть АИМУЗА", url: "https://max.ru/test_aimuza_bot",
      }]] } }],
    },
  })));
});

test("group events preserve large IDs and internal broadcast requests require the separate secret", async t => {
  const store = createChatStore(":memory:");
  t.after(store.close);
  const service = createBroadcastService({ store: store.broadcasts, max: {
    async chat(id) {
      assert.equal(id, "-9223372036854775808");
      return { type: "chat", status: "active", title: "Группа MAX" };
    },
  } });
  const origin = await listen(t, createWebhookServer({
    secret: "webhook-secret", internalSecret, enqueue: store.enqueue, admin: service.admin,
  }));
  const webhook = (type, timestamp) => fetch(`${origin}/webhooks/max`, {
    method: "POST",
    headers: { "X-Max-Bot-Api-Secret": "webhook-secret" },
    body: `{"update_type":"${type}","timestamp":${timestamp},"chat_id":-9223372036854775808,"is_channel":false}`,
  });
  const groups = headers => fetch(`${origin}/internal/admin/broadcast`, {
    method: "POST", headers, body: JSON.stringify({ action: "broadcast-groups", owner }),
  });
  assert.equal((await groups({ "X-Max-Bot-Api-Secret": "webhook-secret" })).status, 403);
  for (const [type, timestamp] of [["bot_added", 1], ["bot_removed", 3], ["bot_added", 2]]) {
    assert.equal((await webhook(type, timestamp)).status, 200);
    const { key, event } = store.nextEvent();
    await service.groupEvent(event);
    store.finishEvent(key);
  }
  assert.deepEqual(await (await groups({ "X-Aimuza-Max-Secret": internalSecret })).json(), { groups: [] });
  assert.equal((await webhook("bot_admin_permissions_changed", 4)).status, 200);
  await service.groupEvent(store.nextEvent().event);
  assert.deepEqual(await (await groups({ "X-Aimuza-Max-Secret": internalSecret })).json(), {
    groups: [{ id: "-9223372036854775808", title: "Группа MAX" }],
  });
});
