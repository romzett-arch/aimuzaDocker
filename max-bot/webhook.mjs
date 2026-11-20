import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";

function readEvent(update) {
  if (!update || typeof update !== "object") return null;
  if (update.update_type==="bot_started" && Number.isSafeInteger(update.timestamp)) {
    const userId=update.user?.user_id;
    if (Number.isSafeInteger(userId) && userId>0 && !update.user.is_bot) {
      return {key:`start:${userId}:${update.timestamp}`,type:"bot_started",userId,chatId:update.chat_id};
    }
  }
  if (update.update_type==="message_created") {
    const {sender,recipient,body}=update.message ?? {};
    if (recipient?.chat_type==="dialog" && !sender?.is_bot && Number.isSafeInteger(sender?.user_id) && sender.user_id>0 &&
        typeof body?.mid==="string" && body.mid.length<=256 && typeof body.text==="string") {
      return {key:`message:${body.mid}`,type:"message_created",userId:sender.user_id,chatId:recipient.chat_id,text:body.text.slice(0,1001)};
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
  try { return {data:JSON.parse(Buffer.concat(chunks).toString("utf8"))}; }
  catch { return {status:400}; }
}

export function createWebhookServer({secret,enqueue}) {
  const expected=Buffer.from(secret);
  return createServer({requestTimeout:15000},async (request,response)=>{
    if (request.method==="GET" && request.url==="/health") {
      response.writeHead(200,{"Content-Type":"application/json"}).end('{"status":"ok"}');
      return;
    }
    if (request.method!=="POST" || request.url!=="/webhooks/max") {
      response.writeHead(404).end();
      return;
    }
    const incoming=request.headers["x-max-bot-api-secret"];
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
      const event=readEvent(data);
      if (event) enqueue(event);
      response.writeHead(200).end();
    } catch {
      console.warn("MAX webhook could not store event");
      response.writeHead(503).end();
    }
  });
}
