import test from 'node:test';
import assert from 'node:assert/strict';
import {assertCoreRestAccess,coreScope,coreReadColumns,assertJoinColumns} from '../src/security/core-rest-policy.js';
import {assertCoreRpcAccess} from '../src/security/core-rpc-policy.js';
import {parseFilters,parseSelect} from '../src/routes/rest-utils.js';
const user={id:'actor',role:'authenticated',app_role:'user'};
const rls={query:async()=>({rows:[{relrowsecurity:true}]})};
test('REST denies unknown, internal and staff resources before any query',async()=>{
 for(const table of ['auth.users','unlisted_table','email_verifications','api_refresh_sessions','api_keys']) await assert.rejects(()=>assertCoreRestAccess(table,user,'read',rls));
 for(const table of ['payments','balance_transactions','track_addons']) {
  await assert.rejects(()=>assertCoreRestAccess(table,null,'read',rls));
  await assert.rejects(()=>assertCoreRestAccess(table,user,'PATCH',rls));
  assert.deepEqual(coreScope(table,user).params,['actor']);
 }
});
test('missing row security is a refusal, including existing allowlisted tables',async()=>{
 await assert.rejects(()=>assertCoreRestAccess('tracks',user,'read',{query:async()=>({rows:[{relrowsecurity:false}]})}));
 await assert.doesNotReject(()=>assertCoreRestAccess('tracks',null,'read',rls));
});
test('public profile queries and embeds cannot select finance or authentication fields',()=>{
 assert(!coreReadColumns('profiles',null,{},'*').includes('balance'));
 assert.throws(()=>coreReadColumns('profiles',null,{},'"email"'));
 assert.throws(()=>coreReadColumns('profiles',null,{balance:'gt.100'},'*'));
 assert.throws(()=>coreReadColumns('profiles',null,{or:'(email.eq.private@example.invalid)'},'*'));
 assert.throws(()=>coreReadColumns('profiles',null,{order:'balance.desc'},'*'));
 assert.throws(()=>coreReadColumns('addon_services',null,{base_cost_credits:'gt.5'},'*'));
 assert.throws(()=>coreReadColumns('addon_services',null,{},'"provider_options"'));
 assert.throws(()=>assertJoinColumns('profiles',['balance'],user));
 assert.throws(()=>parseSelect('secrets:email_verifications(code)','public."tracks"',user));
});
test('unknown and malformed filters cannot broaden a mutation',()=>{
 for(const query of [{id:'unsupported.value'},{id:'not.unknown.x'},{and:'(id.eq.actor,bad)'},{or:'(bad)'},{id:'is.invalid'}]) assert.throws(()=>parseFilters(query));
 const parsed=parseFilters({and:'(user_id.eq.actor,or.(status.eq.ready,status.eq.pending))'});
 assert.match(parsed.where,/AND/);assert.match(parsed.where,/OR/);assert.deepEqual(parsed.params,['actor','ready','pending']);
});
test('internal RPC and admin RPC are not anonymous or ordinary-user capabilities',()=>{
 for(const name of ['get_last_messages','get_unread_counts','admin_add_xp','security_complete_wav']) assert.throws(()=>assertCoreRpcAccess(name,null));
 assert.throws(()=>assertCoreRpcAccess('security_reserve_wav',user));
 assert.throws(()=>assertCoreRpcAccess('radio_award_listen_xp',user));
 assert.throws(()=>assertCoreRpcAccess('admin_get_user_financial_summary',user));
 assert.doesNotThrow(()=>assertCoreRpcAccess('get_hero_stats',null));
});
