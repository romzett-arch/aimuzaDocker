import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import multer from 'multer';
import { ORG,route,member,document,audit,uuid,text,choice,hash,fail,revision,snapshot } from '../services/legal/core.js';
import { ROOT,filePath,validateFile } from '../services/legal/file-rules.js';

const upload=multer({dest:ROOT,limits:{fileSize:25*1024*1024,files:1,fields:4,parts:5}}).single('file');
export function files(router) {
  router.post('/documents/:id/files',route(async(c,req,res)=>{
    const m=await member(c,req.user,true);
    await document(c,m,req.params.id);
    await fs.mkdir(ROOT,{recursive:true});
    try {
      await new Promise((resolve,reject)=>upload(req,res,error=>error?reject(fail(400,'Не удалось загрузить файл (максимум 25 МиБ)')):resolve()));
      if(!req.file) throw fail(400,'Выберите файл');
      const d=await document(c,m,req.params.id,true);
      revision(d,Number(req.body.revision));
      const purpose=choice(req.body.purpose||'attachment',['original','attachment','signed','proof']);
      if(d.status!=='draft' && (!['registered','archived'].includes(d.status)||!['signed','proof'].includes(purpose))) throw fail(409,'Оригинал и вложения зарегистрированного документа неизменяемы');
      const {buffer,mime}=await validateFile(req.file);
      const org=(await c.query('SELECT quota_bytes FROM legal.organizations WHERE id=$1 FOR UPDATE',[ORG])).rows[0];
      const used=Number((await c.query('SELECT COALESCE(sum(size),0) AS size FROM legal.files WHERE organization_id=$1',[ORG])).rows[0].size);
      const docSize=Number((await c.query('SELECT COALESCE(sum(size),0) AS size FROM legal.files WHERE document_id=$1',[d.id])).rows[0].size);
      if(used+buffer.length>Number(org.quota_bytes) || docSize+buffer.length>100*1024*1024) throw fail(413,'Превышен лимит хранилища или документа (100 МиБ)');
      const id=crypto.randomUUID(),name=text(req.file.originalname,255,true).replace(/[\x00-\x1f]/g,'');
      await fs.rename(req.file.path,filePath(id));req.file.path=null;
      const row=(await c.query(`INSERT INTO legal.files(id,organization_id,document_id,name,storage_key,mime,size,sha256,purpose,created_by)
        VALUES($1,$2,$3,$4,$10,$5,$6,$7,$8,$9) RETURNING id,name,mime,size,sha256,purpose,status`,[id,ORG,d.id,name,mime,buffer.length,hash(buffer),purpose,req.user.id,id])).rows[0];
      await c.query("INSERT INTO legal.jobs(document_id,file_id,type) VALUES($1,$2,'scan')",[d.id,id]);
      if(d.status==='draft') {
        const updated=(await c.query('UPDATE legal.documents SET revision=revision+1 WHERE id=$1 RETURNING *',[d.id])).rows[0];
        await snapshot(c,req.user,updated);
      }
      await audit(c,req.user,'file.uploaded','document',d.id,d.case_id,{file_id:id,purpose});return row;
    } finally {if(req.file?.path) await fs.unlink(req.file.path).catch(()=>{});}
  }));
  router.delete('/documents/:id/files/:fileId',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id,true);
    revision(d,req.body.revision);
    if(d.status!=='draft') throw fail(409,'Удалять вложения можно только у черновика');
    const f=(await c.query('SELECT * FROM legal.files WHERE id=$1 AND document_id=$2',[uuid(req.params.fileId),d.id])).rows[0];
    if(!f) throw fail(404,'Файл не найден');
    // Historical versions retain the file; only the current attachment is removed.
    await c.query('UPDATE legal.files SET attached=false WHERE id=$1',[f.id]);
    const updated=(await c.query('UPDATE legal.documents SET revision=revision+1 WHERE id=$1 RETURNING *',[d.id])).rows[0];
    await snapshot(c,req.user,updated);await audit(c,req.user,'file.detached','document',d.id,d.case_id,{file_id:f.id});return {ok:true};
  }));
  router.post('/documents/:id/files/:fileId/retry',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id);
    const result=await c.query(`UPDATE legal.jobs SET status='pending',attempts=0,available_at=now(),last_error=NULL
      WHERE file_id=$1 AND document_id=$2 AND type='scan' AND status='failed' RETURNING id`,[uuid(req.params.fileId),d.id]);
    if(!result.rowCount) throw fail(409,'Проверка выполняется или уже завершена');
    await audit(c,req.user,'file.scan_retried','document',d.id,d.case_id);return {ok:true};
  }));
  router.get('/files/:id/content',route(async(c,req,res)=>{
    const m=await member(c,req.user);
    const f=(await c.query("SELECT * FROM legal.files WHERE id=$1 AND organization_id=$2 AND status='ready'",[uuid(req.params.id),ORG])).rows[0];
    if(!f) throw fail(404,'Файл не найден или ещё не проверен');
    const d=await document(c,m,f.document_id);
    const buffer=await fs.readFile(filePath(f.storage_key));
    if(hash(buffer)!==f.sha256) throw fail(503,'Проверка целостности файла не пройдена');
    await member(c,req.user);
    await audit(c,req.user,'file.downloaded','document',d.id,d.case_id,{file_id:f.id});
    // Commit mandatory audit before sending any bytes.
    await c.query('COMMIT');
    res.locals.legalCommitted=true;
    res.set({'Cache-Control':'private, no-store','Content-Type':f.mime,'X-Content-Type-Options':'nosniff',
      'Content-Disposition':`attachment; filename="document"; filename*=UTF-8''${encodeURIComponent(f.name)}`});
    res.send(buffer);
  }));
}
