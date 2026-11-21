import assert from "node:assert/strict";
import { once } from "node:events";
import { test } from "node:test";
import { createWebhookServer } from "./webhook.mjs";
import { createChatStore } from "./chat-store.mjs";
import { createChatHandler } from "./chat.mjs";
import { startChatWorkers } from "./chat-jobs.mjs";

test("authenticates webhook, queues private conversation text, deduplicates", async t=>{
  const store=createChatStore(":memory:");
  const server=createWebhookServer({secret:"test-secret",enqueue:store.enqueue});
  server.listen(0,"127.0.0.1");
  await once(server,"listening");
  t.after(()=>new Promise(resolve=>server.close(()=>{store.close();resolve();})));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const payload={
    update_type:"message_created",
    message:{sender:{user_id:3},recipient:{chat_type:"dialog",chat_id:40},body:{mid:"message1",text:"Музыка"}},
  };
  const send=(secret,data=payload)=>fetch(origin+"/webhooks/max",{method:"POST",headers:{"X-Max-Bot-Api-Secret":secret},body:JSON.stringify(data)});
  assert.equal((await send("invalid")).status,403);
  assert.equal(store.nextEvent(),undefined);
  assert.deepEqual((await Promise.all(Array.from({length:3},()=>send("test-secret")))).map(r=>r.status),[200,200,200]);
  assert.equal(store.nextEvent().event.text,"Музыка");
  store.finishEvent("message:message1");
  assert.equal((await send("test-secret")).status,200);
  payload.message.recipient.chat_type="chat";
  payload.message.body.mid="message2";
  assert.equal((await send("test-secret")).status,200);
  assert.equal(store.nextEvent(),undefined);
});

test("queues generation and sends a finished file to the same private chat", {timeout:8000}, async t=>{
  const store=createChatStore(":memory:");
  const save=store.saveJob;
  store.saveJob=job=>save(job,0);
  const actions=[];
  const sends=[];
  const delivered=Promise.withResolvers();
  const stop=startChatWorkers({
    store,
    siteUrl:"https://aimuza.test",
    handle:async ()=>{},
    api:async (action,event,body)=>{
      actions.push(action);
      assert.equal(event.userId,25);
      assert.equal(body.ownerId,"owner");
      if (action==="status") return {pending:false,items:[{id:"file",title:"Готовый трек",audioUrl:"http://localhost/storage/v1/object/public/tracks/audio/file.mp3"}]};
      if (action==="media") return new Blob(["mp3"],{type:"audio/mpeg"});
      return {};
    },
    max:{
      upload:async (kind,blob)=>{
        assert.equal(kind,"audio");
        assert.equal(blob.type,"audio/mpeg");
        return {type:"audio",payload:{token:"test-token"}};
      },
      send:async (event,body)=>{
        sends.push(body);
        delivered.resolve({chatId:event.chatId,body});
      },
    },
  });
  t.after(()=>{stop();store.close();});
  store.addJob({id:"job",event:{userId:25,chatId:40},ownerId:"owner",kind:"music",phase:"start"});
  const result=await delivered.promise;
  await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(actions,["start","status","profile","media","profile"]);
  assert.equal(result.chatId,40);
  assert.equal(result.body.attachments[0].type,"audio");
  const info=sends.find(message=>message.text.startsWith("🌍"));
  assert.ok(info,"info message delivered");
  const buttons=info.attachments[0].payload.buttons.flat();
  const download=buttons.find(button=>button.type==="link"&&button.text.startsWith("⬇️"));
  assert.equal(download.text,"⬇️ Скачать MP3");
  assert.equal(download.url,"https://aimuza.test/storage/v1/object/public/tracks/audio/file.mp3");
  assert.ok(buttons.some(button=>button.text==="🔕 Не напоминать"));
  assert.equal(store.nextJob(),undefined);
});

test("starts in MAX, generates all formats and switches to a linked account", async t=>{
  const store=createChatStore(":memory:");
  t.after(store.close);
  const sent=[];
  const apiCalls=[];
  let linked=false;
  let mode="max";
  const handle=createChatHandler({
    store,siteUrl:"https://aimuza.test",
    max:{send:async (_event,body)=>sent.push(body)},
    api:async (action,_event,details)=>{
      apiCalls.push({action,details});
      if (action==="link") return {link:"a".repeat(64),signupCode:"01234567"};
      if (action==="verify") {
        linked=details.code==="01112222";
        if (linked) mode="site";
        return {linked};
      }
      if (action==="switch") {mode=details.mode; return {mode};}
      if (action==="profile") return {ownerId:mode,balance:mode==="site" ? 100 : 50,mode,siteLinked:linked,music:28,image:5,lyrics:3};
      if (action==="payment") return {url:"https://auth.robokassa.ru/Merchant/Index.aspx"};
      if (action==="works") return details.kind==="lyrics"
        ? {items:[{id:"text",title:"Ветер",status:"completed",ready:true}],more:false}
        : {items:[],more:false};
      if (action==="lyric") return {title:"Ветер",lyrics:"Первая строка\nВторая строка"};
      assert.fail(`Unexpected action: ${action}`);
    },
  });
  const send=(text,key=text)=>handle({key,userId:25,chatId:40,text});
  await send("/start");
  assert.match(sent.at(-1).text,/Только в MAX/);
  assert.deepEqual(sent.at(-1).attachments[0].payload.buttons.flat().map(button=>button.text),["🎵 Музыка","✍️ Тексты","🖼️ Картинки","📚 Мои работы","💰 Баланс · 50 ₽","👤 Профиль","❓ Помощь"]);
  await send("Музыка");
  assert.match(sent.at(-1).text,/28 ₽/);
  await send("🎧 Поп");
  assert.match(sent.at(-1).text,/тип вокала/);
  await send("👩 Женский вокал");
  assert.match(sent.at(-1).text,/28 ₽/);
  assert.equal(store.nextJob(),undefined);
  await send("Создать");
  const {id,ownerId}=store.nextJob();
  assert.equal(ownerId,"max");
  await send("Создать");
  assert.equal(store.nextJob().id,id);
  store.finishJob(id);
  assert.equal(store.nextJob(),undefined);
  await send("Картинки");
  await send("Ночной город");
  assert.match(sent.at(-1).text, /картинка для примера/);
  await send("Без референса");
  await send("Создать","image-confirmation");
  assert.equal(store.nextJob().kind,"image");
  store.finishJob(store.nextJob().id);
  await send("Тексты");
  await send("а".repeat(201));
  assert.match(sent.at(-1).text,/200 символов/);
  await send("Песня о ветре");
  assert.match(sent.at(-1).text,/3 ₽/);
  await send("Создать","lyrics-confirmation");
  assert.equal(store.nextJob().kind,"lyrics");
  store.finishJob(store.nextJob().id);
  await send("Мои работы");
  await send("Мои картинки");
  assert.match(sent.at(-1).text,/Пока пусто/);
  await send("Мои тексты");
  await send("1");
  assert.match(sent.at(-1).text,/Первая строка/);
  await send("Мои картинки");
  assert.match(sent.at(-1).text,/Пока пусто/);
  await send("🎧 Сгенерировать трек");
  assert.match(sent.at(-1).text,/жанр/);
  await send("Инди-поп");
  await send("Создать","lyrics-to-music");
  assert.equal(store.nextJob().lyricsId,"text");
  store.finishJob(store.nextJob().id);
  await send("Баланс");
  assert.match(sent.at(-1).text,/50 ₽/);
  await send("Профиль");
  await send("Подключить сайт");
  const url=new URL(sent.at(-1).attachments[0].payload.buttons[0][0].url);
  assert.equal(url.pathname,"/m/max-link");
  assert.equal(url.searchParams.get("signup"),"1");
  assert.equal(url.hash.slice(1),"a".repeat(64));
  await send("01112222");
  await send("Баланс");
  assert.match(sent.at(-1).text,/100 ₽/);
  await send("Пополнить");
  await send("100");
  await send("100");
  assert.equal(apiCalls.filter(call=>call.action==="payment").length,1);
  assert.equal(apiCalls.find(call=>call.action==="payment").details.ownerId,"site");
  assert.equal(sent.at(-1).attachments[0].payload.buttons[0][0].type,"link");
  await send("Только в MAX");
  await send("Баланс");
  assert.match(sent.at(-1).text,/50 ₽/);
});

test("mutes the post-track info and re-enables it from the profile", async t=>{
  const store=createChatStore(":memory:");
  t.after(store.close);
  const sent=[];
  const handle=createChatHandler({
    store,siteUrl:"https://aimuza.test",
    max:{send:async (_event,body)=>sent.push(body)},
    api:async (action,_event)=>{
      if (action==="profile") return {ownerId:"max",balance:50,mode:"max",siteLinked:false,music:28,image:5,lyrics:3};
      assert.fail(`Unexpected action: ${action}`);
    },
  });
  const send=(text,key=text)=>handle({key,userId:25,chatId:40,text});
  await send("🔕 Не напоминать");
  assert.match(sent.at(-1).text,/Профиль/);
  assert.equal(store.setting(25).siteInfoMuted,true);
  await send("Профиль");
  assert.ok(sent.at(-1).attachments[0].payload.buttons.flat().some(button=>button.text==="🔔 Напоминать про сайт"));
  await send("🔔 Напоминать про сайт");
  assert.equal(store.setting(25).siteInfoMuted,false);
  await send("Профиль");
  assert.ok(!sent.at(-1).attachments[0].payload.buttons.flat().some(button=>button.text==="🔔 Напоминать про сайт"));
});

test("delivers generated lyrics as a message to their owner", {timeout:8000}, async t=>{
  const store=createChatStore(":memory:");
  const save=store.saveJob;
  store.saveJob=job=>save(job,0);
  const delivered=Promise.withResolvers();
  const stop=startChatWorkers({
    store,
    handle:async ()=>{},
    api:async (action,event,body)=>{
      assert.equal(event.userId,25);
      assert.equal(body.ownerId,"max-owner");
      if (action==="start") return {accepted:true};
      if (action==="status") return {pending:false,items:[{id:"text",title:"Песня"},{id:"duplicate",title:"Песня"}]};
      assert.equal(action,"lyric");
      assert.equal(body.id, "text");
      return {title:"Песня",lyrics:"Первая строка"};
    },
    max:{send:async (event,body)=>delivered.resolve({chatId:event.chatId,body})},
  });
  t.after(()=>{stop();store.close();});
  store.addJob({id:"job",event:{userId:25,chatId:40},ownerId:"max-owner",kind:"lyrics",phase:"start"});
  const result=await delivered.promise;
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(result.chatId,40);
  assert.equal(result.body.text,"📝 «Песня»\n\nПервая строка");
  assert.deepEqual(store.lastLyrics(25),{lyricsId:"text",ownerId:"max-owner"});
  assert.equal(store.nextJob(),undefined);
});
