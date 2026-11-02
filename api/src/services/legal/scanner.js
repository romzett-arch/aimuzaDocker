import net from 'node:net';

// ClamAV INSTREAM protocol; never execute uploaded content or expose the scanner port.
export function scanBuffer(buffer) {
  return new Promise((resolve,reject)=>{
    const socket=net.createConnection({host:process.env.LEGAL_CLAMAV_HOST||'legal-scanner',port:3310});
    let answer='',finished=false;
    const finish=(error,value)=>{if(finished)return;finished=true;socket.destroy();error?reject(error):resolve(value);};
    socket.setTimeout(60000,()=>finish(new Error('SCANNER_TIMEOUT')));
    socket.on('error',()=>finish(new Error('SCANNER_UNAVAILABLE')));
    socket.on('data',data=>{
      answer+=data.toString();
      if(answer.length>4096) return finish(new Error('SCANNER_INVALID_RESPONSE'));
      if(answer.includes('\0')||answer.includes('\n')) {
        if(/: OK[\0\n]/.test(answer)) finish(null,true);
        else if(answer.includes(' FOUND')) finish(null,false);
        else finish(new Error('SCANNER_FAILED'));
      }
    });
    socket.on('close',()=>{if(!finished)finish(new Error('SCANNER_DISCONNECTED'));});
    socket.on('connect',async()=>{
      try {
        socket.write('zINSTREAM\0');
        for(let offset=0;offset<buffer.length;offset+=65536) {
          const part=buffer.subarray(offset,offset+65536),size=Buffer.alloc(4);size.writeUInt32BE(part.length);
          if(!socket.write(Buffer.concat([size,part]))) await new Promise((done,fail)=>{
            socket.once('drain',done);socket.once('error',fail);
          });
        }
        socket.write(Buffer.alloc(4));
      } catch {finish(new Error('SCANNER_UNAVAILABLE'));}
    });
  });
}
