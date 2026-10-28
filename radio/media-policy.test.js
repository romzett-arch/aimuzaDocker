const test=require('node:test'),assert=require('node:assert/strict');
const {annotation,playbackUri}=require('./lib/media-policy');
const {sendCommand}=require('./lib/liquidsoap');
test('radio metadata cannot add playlist lines or telnet commands',async()=>{
 const metadata=annotation('Title"\nmain.skip\r\n\\evil\0');assert(!/[\r\n\0\\"]/.test(metadata));
 await assert.rejects(()=>sendCommand('main.remaining\nmain.skip'));
});
test('radio accepts canonical media and rejects RIST, path traversal and loopback origins',()=>{
 for(const uri of ['async:rist://attacker.example','rist://attacker.example','/etc/passwd','/opt/aimuza/data/uploads/../../etc/passwd','https://attacker.example/file.mp3','http://127.0.0.1/admin','https://cdn1.suno.ai/file.mp3\nasync:rist://attacker.example'])assert.throws(()=>playbackUri(uri));
 assert.equal(playbackUri('https://cdn1.suno.ai/file.mp3'),'https://cdn1.suno.ai/file.mp3');
 assert.equal(playbackUri('/opt/aimuza/data/uploads/tracks/user/file.mp3'),require('node:path').resolve('/opt/aimuza/data/uploads/tracks/user/file.mp3'));
});
