import { createMaxClient } from "./max-api.mjs";
import { createWebhookServer } from "./webhook.mjs";
import { createChatStore } from "./chat-store.mjs";
import { createAimuzaClient } from "./aimuza.mjs";
import { createChatHandler } from "./chat.mjs";
import { startChatWorkers } from "./chat-jobs.mjs";

const token = process.env.MAX_BOT_TOKEN?.trim();
const secret = process.env.MAX_WEBHOOK_SECRET?.trim();
const internal = process.env.MAX_INTERNAL_SECRET?.trim();
const siteUrl = process.env.MAX_SITE_URL ?? "https://aimuza.ru";
const appUrl = process.env.MAX_APP_URL ?? "https://app.aimuza.ru";
const origin = process.env.MAX_AIMUZA_API ?? "http://api:3000";
if (!token || !secret || !/^[A-Za-z0-9_-]{5,256}$/.test(secret) || !internal || internal.length < 32 ||
    new URL(siteUrl).protocol !== "https:" || new URL(appUrl).protocol !== "https:") {
  console.error("Configure MAX_BOT_TOKEN, MAX_WEBHOOK_SECRET, MAX_INTERNAL_SECRET, MAX_SITE_URL and MAX_APP_URL.");
  process.exit(1);
}

const store = createChatStore(process.env.MAX_BOT_DB ?? ":memory:");
const api = createAimuzaClient(origin,internal);
const max = createMaxClient(token);
const handle = createChatHandler({store,api,max,appUrl});
const stop = startChatWorkers({store,api,max,handle,siteUrl});
store.prune();
const cleanup = setInterval(store.prune,86_400_000);
cleanup.unref();

const server = createWebhookServer({secret,enqueue:store.enqueue});
server.listen(3215,"0.0.0.0",()=>console.info("MAX chat bot ready on port 3215"));
process.once("SIGTERM",()=>{stop();server.close();});
