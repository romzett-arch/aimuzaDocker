const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const groupEvents = new Set(["bot_added", "bot_removed", "bot_admin_permissions_changed"]);
const validChatId = id => typeof id === "string" && /^-?[1-9]\d{0,18}$/.test(id) &&
  BigInt(id) >= -(2n ** 63n) && BigInt(id) < 2n ** 63n;
const activeGroup = chat => chat.type === "chat" && chat.status === "active";
const unavailable = error => [403, 404].includes(error.status);
const outcome = (result, value) => { result.status = value; };

export function readGroupUpdate(update) {
  const { update_type: type, timestamp, chat_id: id, is_channel: channel } = update ?? {};
  if (!groupEvents.has(type) || channel === true ||
      !Number.isSafeInteger(timestamp) || (!Number.isSafeInteger(id) && typeof id !== "string") ||
      !validChatId(String(id))) return null;
  return { key: `${type}:${id}:${timestamp}`, type: "broadcast_group", chatId: String(id), timestamp, removed: type === "bot_removed" };
}

function readableTitle(chat) {
  return typeof chat.title === "string" && chat.title.trim() ? chat.title.trim() : null;
}

export function createBroadcastService({ store, max }) {
  async function groupEvent(event) {
    const { chatId, timestamp, removed } = event;
    if (removed) {
      store.group(chatId, null, false, timestamp);
      return;
    }
    const chat = await max.chat(chatId);
    store.group(chatId, readableTitle(chat), activeGroup(chat), timestamp);
  }

  async function admin(input) {
    const { action, owner, id, text, targets, chatId } = input ?? {};
    if (typeof owner !== "string" || !uuid.test(owner)) return [400, { code: "BAD_INPUT" }];
    if (action === "broadcast-groups") return [200, { groups: store.groups() }];
    if (action === "broadcast-add-group" && validChatId(chatId)) {
      const timestamp = Date.now();
      try {
        const chat = await max.chat(chatId);
        if (activeGroup(chat)) {
          store.group(chatId, readableTitle(chat), true, timestamp);
          const group = store.knownGroup(chatId);
          if (group) return [200, { group }];
        }
      } catch (error) {
        if (!unavailable(error)) throw error;
      }
      return [404, { code: "GROUP_UNAVAILABLE" }];
    }
    if (typeof id !== "string" || !uuid.test(id)) return [400, { code: "BAD_INPUT" }];
    if (action === "broadcast-status") {
      const batch = store.get(id, owner);
      return batch ? [200, report(batch)] : [404, { code: "BROADCAST_NOT_FOUND" }];
    }
    if (action !== "broadcast-send" || typeof text !== "string" || !text.trim() || text.length > 4000 ||
        !Array.isArray(targets) || targets.length === 0 || targets.length > 100 ||
        !targets.every(target => validChatId(target?.id) && typeof target.pin === "boolean") ||
        new Set(targets.map(target => target.id)).size !== targets.length) return [400, { code: "BAD_INPUT" }];

    const normalized = { text: text.trim(), targets: targets.map(({ id, pin }) => ({ id, pin })) };
    const results = normalized.targets.map(({ id, pin }) => {
      const known = store.knownGroup(id);
      return { id, pin, title: known?.title ?? null, status: known ? "queued" : "group_unavailable" };
    });
    const batch = store.start(id, owner, normalized, results);
    if (!batch || JSON.stringify(batch.input) !== JSON.stringify(normalized)) return [409, { code: "BROADCAST_CONFLICT" }];
    return [200, report(batch)];
  }

  async function deliver(batch, result) {
    const id = result.id;
    if (result.status === "sending") return outcome(result, "send_unknown");
    if (result.status === "queued") {
      if (!store.knownGroup(id)) return outcome(result, "group_unavailable");
      try {
        const chat = await max.chat(id);
        if (!activeGroup(chat)) return outcome(result, "group_unavailable");
        result.title = readableTitle(chat) ?? result.title;
        const member = await max.chatMembership(id);
        if (!member.is_admin || !member.permissions?.some(permission =>
          permission === "write" || permission === "post_edit_delete_message")) {
          return outcome(result, "send_forbidden");
        }
      } catch (error) {
        return outcome(result, unavailable(error) ? "group_unavailable" : "send_failed");
      }

      // MAX не поддерживает ключ идемпотентности для POST /messages.
      result.status = "sending";
      store.save(batch);
      try {
        const response = await max.send({ groupId: id }, { text: batch.input.text });
        const mid = response.message?.body?.mid;
        if (!result.pin) return outcome(result, "sent");
        if (typeof mid !== "string" || !mid) return outcome(result, "pin_failed");
        result.mid = mid;
        result.status = "pin_pending";
        store.save(batch);
      } catch (error) {
        if (unavailable(error)) return outcome(result, "send_forbidden");
        const rejected = error.status >= 400 && error.status < 500;
        return outcome(result, rejected ? "send_failed" : "send_unknown");
      }
    }

    try {
      const member = await max.chatMembership(id);
      if (!member.is_admin || !member.permissions?.includes("pin_message")) return outcome(result, "pin_forbidden");
      const { message } = await max.chatPin(id);
      if (message != null) return outcome(result, message.body?.mid === result.mid ? "pinned" : "pin_occupied");
      await max.pin(id, result.mid);
      return outcome(result, "pinned");
    } catch (error) {
      return outcome(result, error.status === 403 ? "pin_forbidden" : "pin_failed");
    }
  }

  async function processNext() {
    const batch = store.next();
    if (!batch) return;
    const result = batch.results.find(isPending);
    if (result) await deliver(batch, result);
    batch.done = !batch.results.some(isPending);
    store.save(batch);
  }

  return { admin, groupEvent, processNext };
}

const isPending = ({ status }) => ["queued", "sending", "pin_pending"].includes(status);
const report = ({ id, results, done }) => ({ id, results: results.map(({ mid: _mid, ...result }) => result), done });

export function startBroadcastWorker(service) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try { await service.processNext(); }
    catch (error) { console.warn("MAX broadcast worker failed", error.name); }
    finally { running = false; }
  }, 500);
  return () => clearInterval(timer);
}
