import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import multer from 'multer';
import { ORG,route,member,caseAccess,document,audit,uuid,text,choice,hash,fail,snapshot } from '../services/legal/core.js';
import { ROOT,filePath,validateFile } from '../services/legal/file-rules.js';

const upload=multer({dest:ROOT,limits:{fileSize:25*1024*1024,files:1,fields:1,fieldSize:12000,parts:2}}).single('file');
function calendarDate(value) {
  if(!value)return null;
  const raw=text(value,10,true);
  if(!/^\d{4}-\d{2}-\d{2}$/.test(raw)||raw.startsWith('0000'))throw fail(400,'Укажите дату документа в формате ГГГГ-ММ-ДД');
  const d=new Date(raw+'T00:00:00Z');
  if(!Number.isFinite(d.getTime())||d.toISOString().slice(0,10)!==raw)throw fail(400,'Некорректная дата документа');
  return raw;
}
function originalName(name) {
  if([...name].every(ch=>ch.charCodeAt(0)<=255)) {
    const bytes=Buffer.from(name,'latin1'),decoded=bytes.toString('utf8');
    if(bytes.equals(Buffer.from(decoded,'utf8')))name=decoded;
  }
  return text(name,255,true).replace(/[\x00-\x1f]/g,'');
}
export function imports(router) {
  // Each selected original is an independent atomic import. Stable keys make retries safe.
  router.post('/documents/import',route(async(c,req,res)=>{
    const m=await member(c,req.user,true);
    await fs.mkdir(ROOT,{recursive:true});
    try {
      await new Promise((resolve,reject)=>upload(req,res,error=>error?reject(fail(400,'Загрузка не выполнена: один файл до 25 МиБ')):resolve()));
      if(!req.file)throw fail(400,'Выберите файл');
      let b;
      try{b=JSON.parse(req.body.metadata);}catch{throw fail(400,'Некорректные сведения о документе');}
      if(!b||Array.isArray(b)||typeof b!=='object')throw fail(400,'Некорректные сведения о документе');
      const caseId=b.case_id?uuid(b.case_id):null,partyId=b.party_id?uuid(b.party_id):null;
      const cs=caseId?await caseAccess(c,m,caseId):null;
      if(!caseId&&m.scope!=='all')throw fail(403,'Выберите назначенное вам дело');
      if(partyId) {
        const valid=await c.query('SELECT id FROM legal.parties WHERE organization_id=$1 AND id=$2',[ORG,partyId]);
        if(!valid.rowCount)throw fail(400,'Контрагент не найден');
        if(m.scope!=='all'&&cs.party_id!==partyId)throw fail(403,'Контрагент должен соответствовать делу');
      }
      const name=originalName(req.file.originalname);
      req.file.originalname=name;
      const {buffer,mime}=await validateFile(req.file);
      const metadata={case_id:caseId,party_id:partyId,title:text(b.title,300,true),
        external_number:text(b.external_number,200),document_date:calendarDate(b.document_date),
        direction:choice(b.direction||'internal',['incoming','outgoing','internal']),
        kind:choice(b.kind||'other',['letter','claim','contract','other']),is_blank:b.is_blank===true};
      const key=uuid(b.import_key),checksum=hash(buffer),requestHash=hash({metadata,name,checksum,user_id:req.user.id});
      await c.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",['legal-import:'+key]);
      const prior=(await c.query('SELECT id,import_hash FROM legal.documents WHERE organization_id=$1 AND import_key=$2',[ORG,key])).rows[0];
      if(prior) {
        if(prior.import_hash!==requestHash)throw fail(409,'Ключ загрузки уже использован для другого документа');
        const d=await document(c,m,prior.id);
        return {id:d.id,title:d.title,replayed:true};
      }
      const org=(await c.query('SELECT quota_bytes FROM legal.organizations WHERE id=$1 FOR UPDATE',[ORG])).rows[0];
      const used=Number((await c.query('SELECT COALESCE(sum(size),0) AS size FROM legal.files WHERE organization_id=$1',[ORG])).rows[0].size);
      if(used+buffer.length>Number(org.quota_bytes))throw fail(413,'Превышен лимит хранилища организации');
      const d=(await c.query(`INSERT INTO legal.documents(organization_id,case_id,party_id,title,kind,direction,
        external_number,document_date,is_blank,source,status,import_key,import_hash,created_by)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'uploaded','archived',$10,$11,$12) RETURNING *,document_date::text AS document_date`,
        [ORG,caseId,partyId,metadata.title,metadata.kind,metadata.direction,metadata.external_number,
          metadata.document_date,metadata.is_blank,key,requestHash,req.user.id])).rows[0];
      const id=crypto.randomUUID();
      await fs.rename(req.file.path,filePath(id));req.file.path=null;
      await c.query(`INSERT INTO legal.files(id,organization_id,document_id,name,storage_key,mime,size,sha256,purpose,created_by)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,'original',$9)`,[id,ORG,d.id,name,id,mime,buffer.length,checksum,req.user.id]);
      await c.query("INSERT INTO legal.jobs(document_id,file_id,type) VALUES($1,$2,'scan')",[d.id,id]);
      await snapshot(c,req.user,d);
      await audit(c,req.user,'document.imported','document',d.id,caseId,{file_id:id,is_blank:metadata.is_blank});
      return {id:d.id,title:d.title,replayed:false};
    } finally {if(req.file?.path)await fs.unlink(req.file.path).catch(()=>{});}
  }));
}
