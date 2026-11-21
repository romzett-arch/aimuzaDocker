import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { editImagePattern } from "./chat-images.mjs";
import { maxIdentity } from "./max-identity.mjs";
import { readGroupUpdate } from "./broadcast.mjs";

function readEvent(update) {
  if (!update || typeof update !== "object") return null;
  if (update.update_type==="bot_started" && Number.isSafeInteger(update.timestamp)) {
    const userId=update.user?.user_id;
    if (Number.isSafeInteger(userId) && userId>0 && !update.user.is_bot) {
      return {key:`start:${userId}:${update.timestamp}`,type:"bot_started",userId,chatId:update.chat_id,
        identity:maxIdentity(update.user,update.timestamp)};
    }
  }
  if (update.update_type==="message_created") {
    const {sender,recipient,body}=update.message ?? {};
    const attachment = Array.isArray(body?.attachments) && body.attachments.find(item => item?.type === "image");
    if (recipient?.chat_type==="dialog" && !sender?.is_bot && Number.isSafeInteger(sender?.user_id) && sender.user_id>0 &&
        typeof body?.mid==="string" && body.mid.length<=256 && (typeof body.text==="string" || attachment)) {
      const url = attachment?.payload?.url;
      return {key:`message:${body.mid}`,type:"message_created",userId:sender.user_id,chatId:recipient.chat_id,
        identity:maxIdentity(sender,update.timestamp),
        text: typeof body.text === "string" ? body.text.slice(0,1001) : "",
        ...(attachment ? { photo: { mid: body.mid, url: typeof url === "string" && url.length <= 4096 ? url : undefined } } : {}),
      };
    }
  }
  if (update.update_type === "message_callback") {
    const { callback, message } = update;
    const userId = callback?.user?.user_id;
    const recipient = message?.recipient;
    if (recipient?.chat_type === "dialog" && !callback?.user?.is_bot && Number.isSafeInteger(userId) && userId > 0 &&
        typeof callback.payload === "string" && editImagePattern.test(callback.payload) &&
        typeof callback.callback_id === "string" && callback.callback_id.length <= 256) {
      return { key: `callback:${callback.callback_id}`, type: "message_callback", userId, chatId: recipient.chat_id,
        callback: callback.payload, callbackId: callback.callback_id, identity: maxIdentity(callback.user,update.timestamp) };
    }
  }
  return null;
}

async function readUpdate(request) {
  const chunks=[];
  let size=0;
  for await (const chunk of request.iterator({destroyOnReturn:false})) {
    size+=chunk.length;
    if (size>128*1024) return {status:413};
    chunks.push(chunk);
  }
  try {
    const data = JSON.parse(Buffer.concat(chunks).toString("utf8"), (key, value, context) =>
      key === "chat_id" && typeof value === "number" && !Number.isSafeInteger(value) ? context.source : value);
    return { data };
  }
  catch { return {status:400}; }
}

export function createWebhookServer({secret,enqueue,internalSecret,admin}) {
  const webhookKey = Buffer.from(secret);
  const adminKey = Buffer.from(internalSecret ?? "");
  return createServer({requestTimeout:15000},async (request,response)=>{
    if (request.method==="GET" && request.url==="/health") {
      response.writeHead(200,{"Content-Type":"application/json"}).end('{"status":"ok"}');
      return;
    }
    const webhook = request.url === "/webhooks/max";
    const internal = admin && adminKey.length >= 32 && request.url === "/internal/admin/broadcast";
    if (request.method!=="POST" || (!webhook && !internal)) {
      response.writeHead(404).end();
      return;
    }
    const expected = webhook ? webhookKey : adminKey;
    const incoming=request.headers[webhook ? "x-max-bot-api-secret" : "x-aimuza-max-secret"];
    const actual=typeof incoming==="string" ? Buffer.from(incoming) : Buffer.alloc(0);
    if (actual.length!==expected.length || !timingSafeEqual(actual,expected)) {
      response.writeHead(403,{Connection:"close"}).end();
      return;
    }
    try {
      const {data,status}=await readUpdate(request);
      if (status) {
        response.writeHead(status,{Connection:"close"}).end();
        return;
      }
      if (internal) {
        const [code, result] = await admin(data);
        response.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store" })
          .end(JSON.stringify(result));
        return;
      }
      const event=readGroupUpdate(data) ?? readEvent(data);
      if (event) enqueue(event);
      response.writeHead(200).end();
    } catch {
      console.warn(internal ? "MAX broadcast request failed" : "MAX webhook could not store event");
      response.writeHead(503).end();
    }
  });
}
