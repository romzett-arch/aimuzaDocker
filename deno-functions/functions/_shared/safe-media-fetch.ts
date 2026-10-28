// Only media origins controlled by us or the configured provider are accepted.
const ORIGINS = new Set(['https://aimuza.ru','https://app.aimuza.ru','https://cdn1.suno.ai','https://cdn2.suno.ai','https://cdn1.sunoapi.org','https://cdn.erweima.ai','https://audiopipe.suno.ai',...(Deno.env.get('MEDIA_ALLOWED_ORIGINS')||'').split(',').filter(Boolean)]);
function publicIp(ip: string): boolean {
  if (ip.includes(':')) return /^[23][0-9a-f]{3}:/i.test(ip);
  const [a,b]=ip.split('.').map(Number);
  return !(a===0||a===10||a===127||a>=224||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&(b===168||b===0))||(a===100&&b>=64&&b<=127)||(a===198&&(b===18||b===19)));
}
export async function safeMediaFetch(raw: string, init: RequestInit={}): Promise<Response> {
  let current=raw;
  for(let redirect=0;redirect<=3;redirect++) {
    const url=new URL(current);
    const internal=(url.origin==='http://ffmpeg-api:3001'&&/^\/output\/[a-zA-Z0-9_.-]+$/.test(url.pathname))||(url.origin==='http://api:3000'&&/^\/storage\/v1\/object\/public\/(tracks|covers|certificates)\//.test(url.pathname));
    if (url.username||url.password||(!internal&&(url.protocol!=='https:'||!ORIGINS.has(url.origin)))) throw new Error('Media origin rejected');
    if (!internal) {
      const records=(await Promise.all(['A','AAAA'].map(type=>Deno.resolveDns(url.hostname,type as 'A'|'AAAA').catch(()=>[])))).flat();
      if(!records.length||records.some(ip=>!publicIp(ip))) throw new Error('Media address rejected');
    }
    const headers=new Headers(init.headers);
    headers.delete('Authorization');headers.delete('apikey');headers.delete('cookie');
    const response=await fetch(url,{...init,headers,redirect:'manual',signal:AbortSignal.timeout(120000)});
    if(response.status>=300&&response.status<400) {
      await response.body?.cancel();
      const location=response.headers.get('location');
      if(!location||redirect===3) throw new Error('Media redirect rejected');
      current=new URL(location,url).href;continue;
    }
    const limit=100*1024*1024;
    if(Number(response.headers.get('content-length'))>limit){await response.body?.cancel();throw new Error('Media size rejected');}
    if(!response.body) return response;
    let size=0;
    const body=response.body.pipeThrough(new TransformStream<Uint8Array,Uint8Array>({transform(chunk,controller){size+=chunk.byteLength;if(size>limit)throw new Error('Media size rejected');controller.enqueue(chunk);}}));
    return new Response(body,{status:response.status,statusText:response.statusText,headers:response.headers});
  }
  throw new Error('Media redirect rejected');
}
