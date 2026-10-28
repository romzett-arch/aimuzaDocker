const test=require('node:test');const assert=require('node:assert/strict');
const {classifyUrl,publicAddress}=require('./safe-download');
test('media URLs reject metadata, private services, credentials, non-HTTPS and unapproved origins',()=>{
 for(const raw of ['http://169.254.169.254/latest/meta-data','http://db:5432/','file:///etc/passwd','https://attacker.example/audio','https://aimuza.ru@attacker.example/audio','http://api:3000/auth/v1/admin/users','http://ffmpeg-api:3001/health']) assert.throws(()=>classifyUrl(raw));
 assert.equal(classifyUrl('http://api:3000/storage/v1/object/public/tracks/user/test.mp3').internal,true);
 assert.equal(classifyUrl('https://cdn1.suno.ai/asset.mp3').internal,false);
});
test('DNS validation rejects all local and mapped address families',()=>{
 for(const ip of ['0.0.0.0','127.0.0.1','10.1.2.3','172.31.0.1','192.168.1.1','169.254.169.254','100.64.0.1','224.0.0.1','::1','::ffff:127.0.0.1','fe80::1','fc00::1']) assert.equal(publicAddress(ip),false,ip);
 assert.equal(publicAddress('8.8.8.8'),true);assert.equal(publicAddress('2606:4700:4700::1111'),true);
});
