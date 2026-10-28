const path=require('node:path');
const ROOT=path.resolve(process.env.LOCAL_STORAGE_PATH||'/opt/aimuza/data/uploads');
const ORIGINS=new Set(['https://aimuza.ru','https://app.aimuza.ru','https://cdn1.suno.ai','https://cdn2.suno.ai','https://cdn1.sunoapi.org','https://cdn.erweima.ai','https://audiopipe.suno.ai']);
function annotation(value,max=2048){return String(value??'').replace(/[\x00-\x1f\x7f\\"]/g,' ').slice(0,max);}
function playbackUri(value){
 const raw=String(value||'');
 if(!raw||raw.length>4096||/[\x00-\x1f\x7f]/.test(raw)) throw Error('Invalid playback URI');
 if(raw.startsWith('/')) {const resolved=path.resolve(raw);if(!resolved.startsWith(ROOT+path.sep))throw Error('Playback file outside media directory');return resolved;}
 const url=new URL(raw);
 if(url.username||url.password)throw Error('Invalid playback credentials');
 if(url.origin==='http://api:3000'&&/^\/storage\/v1\/object\/public\/tracks\//.test(url.pathname))return url.href;
 if(url.protocol!=='https:'||!ORIGINS.has(url.origin))throw Error('Playback origin is not allowed');
 return url.href;
}
module.exports={annotation,playbackUri};
