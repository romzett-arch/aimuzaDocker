import test from 'node:test';import assert from 'node:assert/strict';
import {createRealtimeSecurity,canSubscribe,publicRecord} from './security.js';
import {broadcastChange} from './channels.js';
import { EventEmitter } from 'node:events';
import { createConnectionHandler } from './connections.js';
const claims={sub:'actor',role:'authenticated',session_version:2};
const pool={query:async sql=>sql.includes('auth.users')?{rows:[{id:'actor',version:'2'}]}:{rowCount:0}};
const guard=createRealtimeSecurity(pool,{verify:()=>claims},'test-secret');
test('private subscriptions require identity and known table/schema',()=>{
 assert.equal(canSubscribe('payments','public',null),false);assert.equal(canSubscribe('email_verifications','public',{id:'actor'}),false);assert.equal(canSubscribe('tracks','auth',{id:'actor'}),false);
});
test('ACL checks both owner and current participation before broadcasting',async()=>{
 const ws={user:{id:'actor'},token:'valid'};
 assert.equal(await guard.readable(ws,'payments',{user_id:'other'}),false);
 assert.equal(await guard.readable(ws,'payments',{user_id:'actor'}),true);
 assert.equal(await guard.readable(ws,'messages',{conversation_id:'foreign'}),false);
 claims.session_version=1;assert.equal(await guard.readable(ws,'payments',{user_id:'actor'}),false);claims.session_version=2;
});
test('public track events project private provider metadata and old values',async()=>{
 const row={id:'track',user_id:'owner',is_public:true,status:'completed',moderation_status:'approved',suno_audio_id:'private',description:'secret prompt'};
 assert.equal(publicRecord('tracks',row,null).description,undefined);
 const sent=[];const ws={readyState:1,user:null,send:m=>sent.push(m)};
 await broadcastChange({clients:new Set([ws])},new Map([[ws,new Map([['channel',{pgConfigs:[{table:'tracks',event:'*'}]}]])]]),{table:'tracks',schema:'public',type:'UPDATE',record:row,old_record:row},guard.readable);
 assert.equal(sent.length,1);assert(!sent[0].includes('secret prompt'));assert(!sent[0].includes('private'));
});
test('an expired owner token receives only the public projection of a public track',async()=>{
 const ws={user:{id:'actor'},token:'expired'};
 claims.session_version=1;
 const row={id:'track',user_id:'actor',is_public:true,status:'completed',moderation_status:'approved',description:'private generation prompt'};
 assert.equal(await guard.readable(ws,'tracks',row),true);
 assert.equal(ws.user,null);
 assert.equal(publicRecord('tracks',row,ws.user).description,undefined);
 claims.session_version=2;
});

test('accepts the SDK database subscription with Presence disabled', async () => {
  const clientSubs = new Map();
  const ws = Object.assign(new EventEmitter(), {
    readyState: 1,
    messages: [],
    send(message) { this.messages.push(JSON.parse(message)); },
  });
  const wss = { clients: new Set([ws]) };
  const setUp = createConnectionHandler(wss, clientSubs, new Map(), null, null, guard);
  setUp(ws, { headers: {}, socket: { remoteAddress: 'local-test' } });
  const changes = [{ event: '*', schema: 'public', table: 'notifications', filter: 'user_id=eq.actor' }];

  const join = async (topic, enabled, ref) => {
    ws.emit('message', JSON.stringify([ref, ref, topic, 'phx_join', {
      access_token: 'valid', config: { presence: { key: '', enabled }, postgres_changes: changes },
    }]));
    await new Promise(resolve => setImmediate(resolve));
    return ws.messages.find(message => message[1] === ref && message[3] === 'phx_reply')?.[4];
  };

  const regular = await join('realtime:notifications-actor', false, '1');
  assert.equal(regular.status, 'ok');
  assert.deepEqual(regular.response.postgres_changes, [{ ...changes[0], id: 1 }]);
  assert.equal(clientSubs.get(ws).get('realtime:notifications-actor').presenceKey, undefined);

  const unauthorizedPresence = await join('realtime:notifications-other', true, '2');
  assert.equal(unauthorizedPresence.status, 'error');

  const allowedPresence = await join('realtime:online-users', true, '3');
  assert.equal(allowedPresence.status, 'ok');
  assert.equal(clientSubs.get(ws).get('realtime:online-users').presenceKey, 'actor');
});
