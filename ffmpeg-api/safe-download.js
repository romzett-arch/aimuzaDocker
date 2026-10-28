const dns = require('node:dns').promises;
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
const { pipeline } = require('node:stream/promises');
const { Transform } = require('node:stream');
const fs = require('node:fs');
const fetch = require('node-fetch');

function publicAddress(address) {
  if (net.isIP(address)===4) {
    const [a,b]=address.split('.').map(Number);
    return !(a===0 || a===10 || a===127 || a>=224 || (a===169&&b===254) || (a===172&&b>=16&&b<=31) || (a===192&&(b===168||b===0)) || (a===100&&b>=64&&b<=127) || (a===198&&(b===18||b===19)));
  }
  // Global-unicast IPv6 only; mapped IPv4 and all local ranges are excluded.
  return net.isIP(address)===6 && /^[23][0-9a-f]{3}:/i.test(address);
}
const origins = new Set(['https://aimuza.ru','https://app.aimuza.ru','https://cdn1.suno.ai','https://cdn2.suno.ai','https://cdn1.sunoapi.org','https://cdn.erweima.ai','https://audiopipe.suno.ai',...(process.env.MEDIA_ALLOWED_ORIGINS||'').split(',').filter(Boolean)]);
function classifyUrl(raw) {
  const url=new URL(raw);
  if (url.username || url.password || url.hash) throw new Error('Invalid media URL');
  const internal=(url.origin==='http://api:3000' && /^\/storage\/v1\/object\/(public\/)?(tracks|covers)\//.test(url.pathname)) || (url.origin==='http://ffmpeg-api:3001' && /^\/output\/[a-zA-Z0-9_.-]+$/.test(url.pathname));
  if (!internal && (url.protocol!=='https:' || !origins.has(url.origin))) throw new Error('Media origin is not allowed');
  return {url,internal};
}
async function downloadAudio(req,raw,destination) {
  const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),120000);
  let current=raw;
  try {
    for(let redirect=0;redirect<=3;redirect++) {
      const {url,internal}=classifyUrl(current);
      const records=await dns.lookup(url.hostname,{all:true});
      if (!records.length || (!internal && records.some(r=>!publicAddress(r.address)))) throw new Error('Media address is not public');
      const pinned=records[0];
      const Agent=url.protocol==='https:'?https.Agent:http.Agent;
      const agent=new Agent({lookup:(_host,options,callback)=>options?.all ? callback(null,[pinned]) : callback(null,pinned.address,pinned.family)});
      const headers={'User-Agent':'AIMUZA Media/1.0'};
      if (url.origin==='http://api:3000' && !url.pathname.includes('/object/public/') && req.headers.authorization) headers.Authorization=req.headers.authorization;
      const response=await fetch(url.href,{agent,headers,redirect:'manual',signal:controller.signal});
      if (response.status>=300&&response.status<400) {
        response.body.destroy();agent.destroy();
        const location=response.headers.get('location');
        if (!location || redirect===3) throw new Error('Too many media redirects');
        current=new URL(location,url).href;continue;
      }
      if (!response.ok) {response.body.destroy();agent.destroy();throw new Error('Media download failed');}
      const limit=100*1024*1024;
      let bytes=0;
      const bound=new Transform({transform(chunk,_encoding,done){bytes+=chunk.length;done(bytes>limit?new Error('Media exceeds size limit'):null,chunk);}});
      try {
        if (Number(response.headers.get('content-length'))>limit) throw new Error('Media exceeds size limit');
        await pipeline(response.body,bound,fs.createWriteStream(destination,{flags:'wx'}),{signal:controller.signal});
      } finally {response.body.destroy();agent.destroy();}
      return;
    }
  } catch(error) { await fs.promises.rm(destination,{force:true});throw error; }
  finally {clearTimeout(timeout);}
}
module.exports={downloadAudio,publicAddress,classifyUrl};
