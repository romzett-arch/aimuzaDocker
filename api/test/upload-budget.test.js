import test from 'node:test';import assert from 'node:assert/strict';import {EventEmitter} from 'node:events';
import {createUploadBudget} from '../src/security/upload-budget.js';
function attempt(gate,id,size=1){
 const req=Object.assign(new EventEmitter(),{method:'POST',path:'/tracks/file.mp3',headers:{'content-length':size},user:{id}});
 const res=Object.assign(new EventEmitter(),{statusCode:200,set(){},status(value){this.statusCode=value;return this;},json(){return this;}});
 let accepted=false;gate(req,res,()=>{accepted=true;});return {req,res,accepted};
}
test('upload buffers are bounded across users and released exactly once on abort/close',()=>{
 const gate=createUploadBudget(2),first=attempt(gate,'first');assert(first.accepted);
 assert.equal(attempt(gate,'first').res.statusCode,429);
 const second=attempt(gate,'second');assert(second.accepted);
 assert.equal(attempt(gate,'third').res.statusCode,429);
 first.req.emit('aborted');first.res.emit('close');first.res.emit('finish');
 assert(attempt(gate,'third').accepted);
 assert.equal(attempt(gate,'fourth').res.statusCode,429);
 second.res.emit('finish');assert.equal(attempt(gate,'large',101*1024*1024).res.statusCode,413);
});
