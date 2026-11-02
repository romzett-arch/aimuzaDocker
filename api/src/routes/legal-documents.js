import { ORG,route,member,scope,caseAccess,document,audit,snapshot,hash,uuid,text,choice,date,fail,revision } from '../services/legal/core.js';

async function references(c,m,b) {
  if(b.case_id) await caseAccess(c,m,b.case_id);
  else if(m.scope!=='all') throw fail(403,'Выберите доступное дело');
  if(b.party_id) {
    const p=await c.query('SELECT id FROM legal.parties WHERE id=$1 AND organization_id=$2',[uuid(b.party_id),ORG]);
    if(!p.rowCount) throw fail(400,'Контрагент не найден');
    if(m.scope!=='all') {
      const cs=await caseAccess(c,m,b.case_id);
      if(cs.party_id!==b.party_id) throw fail(403,'Выберите контрагента дела');
    }
  }
  if(b.related_document_id) await document(c,m,b.related_document_id);
  if(b.template_version_id) {
    const t=await c.query('SELECT id FROM legal.template_versions WHERE id=$1 AND organization_id=$2',[uuid(b.template_version_id),ORG]);
    if(!t.rowCount) throw fail(400,'Шаблон не найден');
  }
}
export function documents(router) {
  router.get('/documents',route(async(c,req)=>{
    const m=await member(c,req.user),s=scope(m,'d','case_id');
    const params=[...s.params],q=text(req.query.q,150);
    params.push('%'+q+'%'); const n=params.length;
    let extra='';
    if(req.query.blanks_only==='true')extra+=' AND d.is_blank';
    if(req.query.case_id) {params.push(uuid(req.query.case_id));extra+=` AND d.case_id=$${params.length}`;}
    if(req.query.direction) {params.push(choice(req.query.direction,['incoming','outgoing','internal']));extra+=` AND d.direction=$${params.length}`;}
    if(req.query.status) {params.push(choice(req.query.status,['draft','registered','archived','annulled','deleted']));extra+=` AND d.status=$${params.length}`;}
    const rows=(await c.query(`SELECT d.id,d.title,d.kind,d.direction,d.status,d.revision,d.case_id,d.party_id,d.created_at,d.external_number,d.document_date::text AS document_date,d.source,d.is_blank,
      p.name AS party_name,r.number,r.registered_at,j.status AS pdf_status FROM legal.documents d
      LEFT JOIN legal.parties p ON p.id=d.party_id LEFT JOIN legal.register_entries r ON r.document_id=d.id
      LEFT JOIN legal.jobs j ON j.document_id=d.id AND j.type='pdf'
      WHERE d.organization_id='${ORG}' AND ${s.sql} ${extra}
      AND (d.title ILIKE $${n} OR d.body ILIKE $${n} OR d.external_number ILIKE $${n} OR COALESCE(r.number,'') ILIKE $${n} OR COALESCE(p.name,'') ILIKE $${n})
      ORDER BY d.created_at DESC LIMIT 500`,params)).rows;
    return rows;
  }));
  router.post('/documents',route(async(c,req)=>{
    const m=await member(c,req.user,true),b=req.body;
    await references(c,m,b);
    const row=(await c.query(`INSERT INTO legal.documents(organization_id,case_id,party_id,template_version_id,related_document_id,title,kind,direction,recipient,external_number,received_at,body,created_by)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING *`,
      [ORG,b.case_id||null,b.party_id||null,b.template_version_id||null,b.related_document_id||null,text(b.title,300,true),choice(b.kind||'letter',['letter','claim','contract','other']),
        choice(b.direction||'outgoing',['outgoing','incoming','internal']),text(b.recipient,3000),text(b.external_number,200),b.received_at?date(b.received_at).slice(0,10):null,text(b.body,100000),req.user.id])).rows[0];
    await snapshot(c,req.user,row);await audit(c,req.user,'document.created','document',row.id,row.case_id);return row;
  }));
  router.get('/documents/:id',route(async(c,req)=>{
    const m=await member(c,req.user),d=await document(c,m,req.params.id);
    const versions=(await c.query('SELECT id,revision,created_at,created_by FROM legal.document_versions WHERE document_id=$1 ORDER BY revision DESC',[d.id])).rows;
    const files=(await c.query('SELECT id,name,mime,size,sha256,purpose,status,created_at FROM legal.files WHERE document_id=$1 AND attached ORDER BY created_at',[d.id])).rows;
    const events=(await c.query('SELECT * FROM legal.correspondence_events WHERE document_id=$1 ORDER BY occurred_at DESC',[d.id])).rows;
    const registration=(await c.query('SELECT * FROM legal.register_entries WHERE document_id=$1',[d.id])).rows[0]||null;
    const pdfJob=(await c.query("SELECT id,status,attempts,last_error FROM legal.jobs WHERE document_id=$1 AND type='pdf'",[d.id])).rows[0]||null;
    await audit(c,req.user,'document.viewed','document',d.id,d.case_id);
    return {...d,versions,files,events,registration,pdfJob};
  }));
  router.get('/documents/:id/versions/:versionId',route(async(c,req)=>{
    const m=await member(c,req.user),d=await document(c,m,req.params.id);
    const row=(await c.query('SELECT * FROM legal.document_versions WHERE document_id=$1 AND id=$2',[d.id,uuid(req.params.versionId)])).rows[0];
    if(!row) throw fail(404,'Версия не найдена');
    await audit(c,req.user,'version.viewed','document',d.id,d.case_id,{version_id:row.id}); return row;
  }));
  router.patch('/documents/:id',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id,true),b=req.body;
    revision(d,b.revision);
    if(d.status!=='draft') throw fail(409,'Редактировать можно только черновик');
    const merged={...d,...Object.fromEntries(['case_id','party_id','template_version_id','related_document_id','title','kind','direction','recipient','external_number','received_at','body'].filter(k=>b[k]!==undefined).map(k=>[k,b[k]]))};
    await references(c,m,merged);
    // A document with existing files cannot be moved into a different scope.
    if(merged.case_id!==d.case_id) throw fail(400,'Для другого дела создайте связанный документ');
    const updated=(await c.query(`UPDATE legal.documents SET party_id=$2,template_version_id=$3,related_document_id=$4,title=$5,kind=$6,direction=$7,recipient=$8,
      external_number=$9,received_at=$10,body=$11,revision=revision+1 WHERE id=$1 RETURNING *`,
      [d.id,merged.party_id||null,merged.template_version_id||null,merged.related_document_id||null,text(merged.title,300,true),choice(merged.kind,['letter','claim','contract','other']),
        choice(merged.direction,['outgoing','incoming','internal']),text(merged.recipient,3000),text(merged.external_number,200),merged.received_at?date(String(merged.received_at)).slice(0,10):null,text(merged.body,100000)])).rows[0];
    await snapshot(c,req.user,updated);await audit(c,req.user,'document.updated','document',d.id,d.case_id); return updated;
  }));
  router.post('/documents/:id/register',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id,true),b=req.body;
    const key=uuid(b.idempotency_key),requestHash=hash({document_id:d.id,revision:b.revision});
    await c.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",['legal-register:'+key]);
    const replay=(await c.query('SELECT * FROM legal.register_entries WHERE organization_id=$1 AND idempotency_key=$2',[ORG,key])).rows[0];
    if(replay) {if(replay.request_hash!==requestHash) throw fail(409,'Ключ запроса уже использован');return replay;}
    const existing=(await c.query('SELECT * FROM legal.register_entries WHERE document_id=$1',[d.id])).rows[0];
    if(existing) return existing;
    revision(d,b.revision);
    if(d.status!=='draft') throw fail(409,'Документ не является черновиком');
    const files=(await c.query('SELECT id,name,sha256,status,purpose FROM legal.files WHERE document_id=$1 AND attached ORDER BY id',[d.id])).rows;
    if(files.some(f=>f.status!=='ready')) throw fail(409,'Дождитесь проверки всех файлов. Отклонённые вложения нужно удалить из черновика.');
    if(!d.body.trim() && !files.length) throw fail(400,'Добавьте текст или оригинал документа');
    if(d.direction==='outgoing' && !d.recipient.trim()) throw fail(400,'Укажите адресата');
    if(d.direction==='incoming' && !d.received_at) throw fail(400,'Укажите дату получения');
    const org=(await c.query('SELECT id,name,details FROM legal.organizations WHERE id=$1 FOR SHARE',[ORG])).rows[0];
    if(d.direction==='outgoing' && !org.details.trim()) throw fail(400,'Сначала заполните реквизиты организации в разделе бланков');
    const template=d.template_version_id?(await c.query('SELECT * FROM legal.template_versions WHERE id=$1',[d.template_version_id])).rows[0]:{header:org.name,footer:'',body:''};
    const year=(await c.query("SELECT extract(year FROM now() AT TIME ZONE 'Europe/Moscow')::int AS year")).rows[0].year;
    const count=(await c.query(`INSERT INTO legal.register_counters(organization_id,direction,year,last_number) VALUES($1,$2,$3,1)
      ON CONFLICT(organization_id,direction,year) DO UPDATE SET last_number=legal.register_counters.last_number+1 RETURNING last_number`,[ORG,d.direction,year])).rows[0].last_number;
    const number=`АИМ-${{outgoing:'ИСХ',incoming:'ВХ',internal:'ВН'}[d.direction]}-${year}-${String(count).padStart(6,'0')}`;
    const updated=(await c.query("UPDATE legal.documents SET status='registered',revision=revision+1 WHERE id=$1 RETURNING *",[d.id])).rows[0];
    const v=await snapshot(c,req.user,updated,{organization:org,template,files,number});
    const entry=(await c.query(`INSERT INTO legal.register_entries(organization_id,document_id,version_id,direction,year,sequence,number,registered_by,idempotency_key,request_hash)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *`,[ORG,d.id,v.id,d.direction,year,count,number,req.user.id,key,requestHash])).rows[0];
    await c.query("INSERT INTO legal.jobs(document_id,type) VALUES($1,'pdf')",[d.id]);
    await audit(c,req.user,'document.registered','document',d.id,d.case_id,{number});return entry;
  }));
  router.post('/documents/:id/state',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id,true),b=req.body;
    revision(d,b.revision);
    const target=choice(b.status,['archived','annulled','deleted','draft']);
    const transitions={draft:['deleted'],deleted:['draft'],registered:['archived','annulled'],archived:['annulled'],annulled:[]};
    if(!transitions[d.status].includes(target)) throw fail(409,'Недопустимый переход состояния');
    const reason=text(b.reason,1000,target==='annulled');
    if(target==='annulled') await c.query('UPDATE legal.register_entries SET annul_reason=$2 WHERE document_id=$1',[d.id,reason]);
    const row=(await c.query('UPDATE legal.documents SET status=$2,revision=revision+1 WHERE id=$1 RETURNING *',[d.id,target])).rows[0];
    await audit(c,req.user,'document.'+target,'document',d.id,d.case_id,{reason});return row;
  }));
  router.post('/documents/:id/events',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id,true),b=req.body;
    if(!['registered','archived'].includes(d.status)) throw fail(409,'Сначала зарегистрируйте документ');
    const row=(await c.query(`INSERT INTO legal.correspondence_events(organization_id,document_id,type,method,occurred_at,notes,created_by)
      VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`,[ORG,d.id,choice(b.type,['sent','delivered','received','response']),text(b.method,300,true),date(b.occurred_at),text(b.notes,3000),req.user.id])).rows[0];
    await audit(c,req.user,'correspondence.recorded','document',d.id,d.case_id,{type:row.type});return row;
  }));
  router.post('/documents/:id/retry-pdf',route(async(c,req)=>{
    const m=await member(c,req.user,true),d=await document(c,m,req.params.id);
    const result=await c.query("UPDATE legal.jobs SET status='pending',attempts=0,available_at=now(),last_error=NULL WHERE document_id=$1 AND type='pdf' AND status='failed' RETURNING id",[d.id]);
    if(!result.rowCount) throw fail(409,'Нет неудачного задания PDF');
    await audit(c,req.user,'pdf.retried','document',d.id,d.case_id);return {ok:true};
  }));
}
