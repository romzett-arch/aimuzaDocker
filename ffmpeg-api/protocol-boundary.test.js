const test=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const http=require('node:http');
const {execFileAsync}=require('/app/utils');
test('FFmpeg accepts local WAV and cannot turn a playlist into a network request',async()=>{
 let requests=0;const server=http.createServer((_req,res)=>{requests++;res.end('fixture');});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const base='/tmp/security-protocol-'+process.pid, wav=base+'.wav', manifest=base+'.m3u8';
 try {
  const pcm=Buffer.alloc(44+8820);pcm.write('RIFF',0);pcm.writeUInt32LE(pcm.length-8,4);pcm.write('WAVEfmt ',8);pcm.writeUInt32LE(16,16);pcm.writeUInt16LE(1,20);pcm.writeUInt16LE(1,22);pcm.writeUInt32LE(44100,24);pcm.writeUInt32LE(88200,28);pcm.writeUInt16LE(2,32);pcm.writeUInt16LE(16,34);pcm.write('data',36);pcm.writeUInt32LE(8820,40);fs.writeFileSync(wav,pcm);
  const good=await execFileAsync('ffprobe',['-v','error','-show_entries','format=duration','-of','json',wav],{timeout:5000});
  assert(Number(JSON.parse(good.stdout).format.duration)>0);
  fs.writeFileSync(manifest,`#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:${server.address().port}/probe.ts\n#EXT-X-ENDLIST\n`);
  await assert.rejects(()=>execFileAsync('ffprobe',['-v','error','-show_format',manifest],{timeout:5000}));
  assert.equal(requests,0,'Untrusted media must never initiate an FFmpeg network request');
 } finally {fs.rmSync(wav,{force:true});fs.rmSync(manifest,{force:true});await new Promise(resolve=>server.close(resolve));}
});
