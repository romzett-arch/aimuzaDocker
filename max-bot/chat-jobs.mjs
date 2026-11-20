import { errorButtons, labels, message, presentError, sendLyrics, title } from "./chat-messages.mjs";

export function startChatWorkers({store,api,max,handle}) {
  let processingEvent = false;
  let processingJob = false;
  let stopped = false;

  async function processEvent() {
    if (processingEvent || stopped) return;
    const entry = store.nextEvent();
    if (!entry) return;
    processingEvent = true;
    try {
      await handle(entry.event);
      store.finishEvent(entry.key);
      console.info("MAX reply delivered:",entry.event.type);
    } catch (error) {
      console.warn("MAX chat reply failed:",error.status ?? error.name);
      if (entry.attempts >= 5) store.finishEvent(entry.key);
      else store.retryEvent(entry.key,Math.min(60_000,2000 * 2**entry.attempts));
    } finally { processingEvent = false; }
  }

  async function processJob() {
    if (processingJob || stopped) return;
    const job = store.nextJob();
    if (!job) return;
    processingJob = true;
    const call = (action, body={}) => api(action,job.event,{...body,ownerId:job.ownerId});
    try {
      if (Date.now() - job.created > 20 * 60_000) {
        await max.send(job.event,message("⌛️ Задание всё ещё в работе. Позже проверь в «Моих работах» — результат появится там.",[[labels.works, labels.menu]]));
        store.finishJob(job.id);
      } else if (job.phase==="start") {
        await call("start",{id:job.id,kind:job.kind,prompt:job.prompt,price:job.price,lyricsId:job.lyricsId});
        store.saveJob({...job,phase:"status",prompt:undefined},3000);
      } else if (job.phase==="status") {
        const result = await call("status",{id:job.id,kind:job.kind});
        if (result.pending) store.saveJob(job,12_000);
        else if (result.items.length) store.saveJob({...job,phase:"deliver",items:result.items});
        else {
          await max.send(job.event,message("😔 Генерация не завершилась. Проверь статус в «Моих работах».",[[labels.works, labels.menu]]));
          store.finishJob(job.id);
        }
      } else if (job.kind === "lyrics") {
        const lyric = await call("lyric", { id: job.items[0].id });
        await sendLyrics(body => max.send(job.event, body), lyric, [[labels.songFromLyrics], [labels.worksLyrics, labels.menu]]);
        store.setLastLyrics(job.event.userId, { lyricsId: job.items[0].id, ownerId: job.ownerId });
        if (job.items.length === 1) store.finishJob(job.id);
        else store.saveJob({ ...job, items: job.items.slice(1), retries: 0 }, 1000);
      } else {
        await call("profile");
        const item = job.items[0];
        const kind = job.kind==="image" ? "image" : "audio";
        const blob = job.attachment ? null : await call("media",{kind:job.kind,id:item.id});
        const attachment = job.attachment ?? await max.upload(kind,blob);
        if (!job.attachment) store.saveJob({...job,attachment},3000);
        else {
          const caption = `${job.kind==="image" ? "🖼️" : "🎧"} «${title(item.title)}»${job.kind==="image" ? " готова" : " готов"}!`;
          // MAX не принимает inline-кнопки вместе с медиа — вложение уходит без клавиатуры.
          await max.send(job.event,{text:caption,attachments:[attachment]});
          if (job.items.length===1) store.finishJob(job.id);
          else store.saveJob({...job,attachment:undefined,items:job.items.slice(1),retries:0},1000);
        }
      }
    } catch (error) {
      const retries = (job.retries ?? 0) + 1;
      const final = error.status===401 || (job.phase==="start" && error.status>=400 && error.status<500) || retries>=7;
      if (final) {
        const body = presentError(error);
        await max.send(job.event,message(body,errorButtons(error))).catch(()=>{});
        store.finishJob(job.id);
      } else store.saveJob({...job,retries},Math.min(60_000,3000*retries));
      console.warn("MAX job failed:",job.phase,error.status ?? error.name);
    } finally { processingJob = false; }
  }

  const timer = setInterval(()=>{ void processEvent(); void processJob(); },750);
  return () => { stopped = true; clearInterval(timer); };
}
