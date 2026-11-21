import { errorButtons, isInsufficientFunds, labels, linkButton, lyricsMessages, message, presentError, title } from "./chat-messages.mjs";
import { imageActions } from "./chat-images.mjs";

export function startChatWorkers({store,api,max,handle,siteUrl}) {
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
      if (entry.event.identity) {
        await api("identity", entry.event, { identity: entry.event.identity }).catch(error => {
          console.warn("MAX identity update failed:", error.status ?? error.name);
        });
      }
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
        const reference = job.referenceId ? store.reference(job.event.userId, job.referenceId) : undefined;
        if (job.referenceId && !reference) {
          const error = new Error("INVALID_REFERENCE");
          error.status = 422;
          throw error;
        }
        await call("start",{id:job.id,kind:job.kind,prompt:job.prompt,price:job.price,lyricsId:job.lyricsId,imageId:job.imageId,reference});
        store.saveJob({...job,phase:"status",prompt:undefined},3000);
      } else if (job.phase==="status") {
        const result = await call("status",{id:job.id,kind:job.kind});
        if (result.pending) store.saveJob(job,12_000);
        else if (result.items.length) store.saveJob({...job,phase:"deliver",items:result.items,urls:result.items.map(i=>i.audioUrl).filter(Boolean)});
        else {
          await max.send(job.event,message("😔 Генерация не завершилась. Проверь статус в «Моих работах».",[[labels.works, labels.menu]]));
          store.finishJob(job.id);
        }
      } else if (job.kind === "lyrics") {
        const lyric = await call("lyric", { id: job.items[0].id });
        store.setLastLyrics(job.event.userId, { lyricsId: job.items[0].id, ownerId: job.ownerId });
        const chunks = lyricsMessages(lyric, [[labels.songFromLyrics], [labels.worksLyrics, labels.menu]]);
        for (const [index, body] of chunks.entries()) {
          if (index < (job.sentChunks ?? 0)) continue;
          await max.send(job.event, body);
          job.sentChunks = index + 1;
          store.saveJob(job);
        }
        store.finishJob(job.id);
      } else {
        await call("profile");
        const item = job.items[0];
        const kind = job.kind==="image" ? "image" : "audio";
        const blob = job.attachment ? null : await call("media",{kind:job.kind,id:item.id});
        const attachment = job.attachment ?? await max.upload(kind,blob);
        if (!job.attachment) { store.saveJob({...job,attachment},3000); return; }
        if (!job.delivered) {
          const caption = job.kind === "image" ? "🖼️ Картинка готова!" : `🎧 «${title(item.title)}» готов!`;
          // MAX не принимает inline-кнопки вместе с медиа — вложение уходит без клавиатуры.
          await max.send(job.event,{text:caption,attachments:[attachment]});
          if (job.items.length===1) { store.saveJob({...job,delivered:true},0); job.delivered=true; }
          else { store.saveJob({...job,attachment:undefined,items:job.items.slice(1),retries:0},1000); return; }
        }
        // Справка сразу после последней версии трека: MP3, сайт, площадки, соцсеть.
        // delivered сохранён до справки — при сбое ретрай не пошлёт трек повторно.
        if (job.kind==="music" && !store.setting(job.event.userId).siteInfoMuted) {
          const downloads = (job.urls ?? [])
            .map(url => { try { return new URL(new URL(url).pathname, siteUrl).href; } catch { return null; } })
            .filter(Boolean)
            .map((href, i, all) => linkButton(all.length>1 ? `⬇️ Версия ${i+1}` : "⬇️ Скачать MP3", href));
          await max.send(job.event,message(
            "🌍 Это не всё: с аккаунтом сайта трек можно выпустить на площадки (стриминги), а в соцсети AIMUZA — найти слушателей. Подключение прямо в чате: 👤 Профиль → 🔗 Подключить сайт.",
            [
              ...(downloads.length ? [downloads] : []),
              [labels.link],
              [labels.muteInfo, labels.menu],
            ],
          ));
        }
        if (job.kind === "image") await max.send(job.event, imageActions(item.id, job.ownerId));
        store.finishJob(job.id);
      }
    } catch (error) {
      const retries = (job.retries ?? 0) + 1;
      const final = error.status===401 || (job.phase==="start" && error.status>=400 && error.status<500) || retries>=7;
      if (job.phase === "start" && isInsufficientFunds(error)) {
        store.deferOrder(job);
        await max.send(job.event, message("😢 Не хватает средств. Заказ сохранён на сутки. После пополнения нажми «Продолжить генерацию».", [
          [labels.topUpOrder], [labels.retryOrder], [labels.menu],
        ])).catch(() => {});
      } else if (final) {
        const body = presentError(error);
        await max.send(job.event,message(body,errorButtons(error))).catch(()=>{});
        store.finishJob(job.id);
      } else {
        // MAX иногда отдаёт attachment.not.ready — тогда следующий ретрай
        // загружает файл заново со свежим токеном вместо кэшированного.
        const notReady = typeof error.message==="string" && error.message.includes("attachment.not.ready");
        store.saveJob(notReady ? {...job,attachment:undefined,retries} : {...job,retries},Math.min(60_000,3000*retries));
      }
      console.warn("MAX job failed:",job.phase,error.status ?? error.name,error.message);
    } finally { processingJob = false; }
  }

  const timer = setInterval(()=>{ void processEvent(); void processJob(); },750);
  return () => { stopped = true; clearInterval(timer); };
}
