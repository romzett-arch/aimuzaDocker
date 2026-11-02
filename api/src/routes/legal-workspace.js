import { ORG,route,member,scope,caseAccess,document,targetMember,audit,uuid,text,choice,date,fail,revision,notify } from '../services/legal/core.js';

export function workspace(router) {
  router.get('/cases',route(async(c,req)=>{
    const m=await member(c,req.user),s=scope(m,'d','id');
    return (await c.query(`SELECT d.*,p.name AS party_name FROM legal.cases d LEFT JOIN legal.parties p ON p.id=d.party_id
      WHERE d.organization_id='${ORG}' AND ${s.sql} ORDER BY d.created_at DESC LIMIT 500`,s.params)).rows;
  }));
  router.post('/cases',route(async(c,req)=>{
    const m=await member(c,req.user,true),b=req.body;
    if(m.scope!=='all') throw fail(403,'Создавать дела может юрист с доступом ко всему кабинету');
    if(b.responsible_id) await targetMember(c,b.responsible_id,null);
    const row=(await c.query(`INSERT INTO legal.cases(organization_id,title,description,party_id,responsible_id,created_by)
      VALUES($1,$2,$3,$4,$5,$6) RETURNING *`,[ORG,text(b.title,300,true),text(b.description,10000),b.party_id?uuid(b.party_id):null,b.responsible_id?uuid(b.responsible_id):req.user.id,req.user.id])).rows[0];
    await audit(c,req.user,'case.created','case',row.id,row.id);
    return row;
  }));
  router.get('/cases/:id',route(async(c,req)=>{
    const m=await member(c,req.user),row=await caseAccess(c,m,req.params.id);
    await audit(c,req.user,'case.viewed','case',row.id,row.id);
    return row;
  }));
  router.patch('/cases/:id',route(async(c,req)=>{
    const m=await member(c,req.user,true),id=uuid(req.params.id);
    await c.query('SELECT id FROM legal.cases WHERE id=$1 FOR UPDATE',[id]);
    const row=await caseAccess(c,m,id),b=req.body;
    revision(row,b.revision);
    const status=choice(b.status||row.status,['open','in_progress','closed','archived']);
    if(['closed','archived'].includes(row.status)&&!['closed','archived'].includes(status)) text(b.reason,1000,true);
    if(b.responsible_id) await targetMember(c,b.responsible_id,id);
    const updated=(await c.query(`UPDATE legal.cases SET title=$2,description=$3,status=$4,responsible_id=$5,revision=revision+1 WHERE id=$1 RETURNING *`,
      [id,b.title===undefined?row.title:text(b.title,300,true),b.description===undefined?row.description:text(b.description,10000),status,b.responsible_id?uuid(b.responsible_id):row.responsible_id])).rows[0];
    await audit(c,req.user,'case.updated','case',id,id,{status,reason:text(b.reason,1000)});
    return updated;
  }));
  router.get('/parties',route(async(c,req)=>{
    const m=await member(c,req.user),s=scope(m,'d','id',1);
    return (await c.query(`SELECT p.* FROM legal.parties p WHERE p.organization_id='${ORG}' AND
      (${m.scope==='all'?'TRUE':`EXISTS(SELECT 1 FROM legal.cases d WHERE d.party_id=p.id AND ${s.sql})`}) ORDER BY p.name LIMIT 500`,s.params)).rows;
  }));
  router.post('/parties',route(async(c,req)=>{
    const m=await member(c,req.user,true);
    if(m.scope!=='all') throw fail(403,'Создавать контрагентов может юрист с полным доступом');
    const row=(await c.query('INSERT INTO legal.parties(organization_id,name,details) VALUES($1,$2,$3) RETURNING *',[ORG,text(req.body.name,300,true),text(req.body.details,10000)])).rows[0];
    await audit(c,req.user,'party.created','party',row.id); return row;
  }));
  router.patch('/parties/:id',route(async(c,req)=>{
    const m=await member(c,req.user,true);
    if(m.scope!=='all') throw fail(403,'Требуется полный доступ');
    const row=(await c.query('SELECT * FROM legal.parties WHERE id=$1 AND organization_id=$2 FOR UPDATE',[uuid(req.params.id),ORG])).rows[0];
    if(!row) throw fail(404,'Контрагент не найден');
    revision(row,req.body.revision);
    const updated=(await c.query('UPDATE legal.parties SET name=$2,details=$3,revision=revision+1 WHERE id=$1 RETURNING *',[row.id,text(req.body.name,300,true),text(req.body.details,10000)])).rows[0];
    await audit(c,req.user,'party.updated','party',row.id); return updated;
  }));
  router.get('/members',route(async(c,req)=>{
    const m=await member(c,req.user);
    // Role-based administrators are eligible even without a legal membership row.
    const s=scope(m,'d','id');
    return (await c.query(`WITH eligible AS (
      SELECT r.user_id,true AS permanent,'lawyer'::text AS profile FROM public.user_roles r WHERE r.role::text IN ('admin','super_admin')
      UNION ALL SELECT m.user_id,false,m.profile FROM legal.memberships m WHERE m.organization_id='${ORG}'
      AND m.revoked_at IS NULL AND (m.expires_at IS NULL OR m.expires_at>now())
      AND NOT EXISTS(SELECT 1 FROM public.user_roles r WHERE r.user_id=m.user_id AND r.role::text IN ('admin','super_admin')))
      SELECT e.user_id,p.username,e.profile FROM eligible e JOIN auth.users u ON u.id=e.user_id LEFT JOIN public.profiles p ON p.user_id=e.user_id
      WHERE u.email_confirmed_at IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=u.id AND b.is_active AND b.unblocked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at>now()))
      AND (${m.scope==='all'?'TRUE':`e.permanent OR e.user_id=$1 OR EXISTS(SELECT 1 FROM legal.case_members cm JOIN legal.cases d ON d.id=cm.case_id WHERE cm.user_id=e.user_id AND ${s.sql})`})`,s.params)).rows;
  }));
  router.get('/templates',route(async(c,req)=>{
    await member(c,req.user);
    return (await c.query(`SELECT t.title,v.* FROM legal.templates t JOIN legal.template_versions v ON v.template_id=t.id AND v.revision=t.revision WHERE t.organization_id=$1 ORDER BY t.title`,[ORG])).rows;
  }));
  router.post('/templates',route(async(c,req)=>{
    const m=await member(c,req.user,true),b=req.body;
    if(!m.manage_templates) throw fail(403,'Право управления бланками не назначено');
    let t;
    if(b.template_id) {
      t=(await c.query('SELECT * FROM legal.templates WHERE id=$1 AND organization_id=$2 FOR UPDATE',[uuid(b.template_id),ORG])).rows[0];
      if(!t) throw fail(404,'Шаблон не найден');
      revision(t,b.revision);
      t=(await c.query('UPDATE legal.templates SET title=$2,revision=revision+1 WHERE id=$1 RETURNING *',[t.id,text(b.title,300,true)])).rows[0];
    } else t=(await c.query('INSERT INTO legal.templates(organization_id,title) VALUES($1,$2) RETURNING *',[ORG,text(b.title,300,true)])).rows[0];
    const v=(await c.query(`INSERT INTO legal.template_versions(organization_id,template_id,revision,body,header,footer,created_by) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
      [ORG,t.id,t.revision,text(b.body,60000),text(b.header,3000,true),text(b.footer,3000),req.user.id])).rows[0];
    await audit(c,req.user,'template.published','template',t.id); return v;
  }));
  router.get('/organization',route(async(c,req)=>{
    await member(c,req.user); return (await c.query('SELECT id,name,details,revision FROM legal.organizations WHERE id=$1',[ORG])).rows[0];
  }));
  router.patch('/organization',route(async(c,req)=>{
    const m=await member(c,req.user,true);
    if(!m.manage_templates) throw fail(403,'Право изменения реквизитов не назначено');
    const row=(await c.query('SELECT * FROM legal.organizations WHERE id=$1 FOR UPDATE',[ORG])).rows[0];
    revision(row,req.body.revision);
    const updated=(await c.query('UPDATE legal.organizations SET name=$2,details=$3,revision=revision+1 WHERE id=$1 RETURNING id,name,details,revision',
      [ORG,text(req.body.name,300,true),text(req.body.details,5000,true)])).rows[0];
    await c.query('INSERT INTO legal.organization_versions(organization_id,revision,name,details) VALUES($1,$2,$3,$4)',[ORG,updated.revision,updated.name,updated.details]);
    await audit(c,req.user,'organization.updated','organization',ORG); return updated;
  }));
  router.get('/tasks',route(async(c,req)=>{
    const m=await member(c,req.user),s=scope(m,'t','case_id');
    return (await c.query(`SELECT t.*,p.username AS responsible_name FROM legal.tasks t LEFT JOIN public.profiles p ON p.user_id=t.responsible_id
      WHERE t.organization_id='${ORG}' AND ${s.sql} ORDER BY t.due_at LIMIT 500`,s.params)).rows;
  }));
  router.post('/tasks',route(async(c,req)=>{
    const m=await member(c,req.user,true),b=req.body;
    let caseId=b.case_id?uuid(b.case_id):null;
    if(b.document_id) {
      const d=await document(c,m,b.document_id);
      if(caseId && caseId!==d.case_id) throw fail(400,'Дело задачи не совпадает с делом документа');
      caseId=d.case_id;
    } else if(caseId) await caseAccess(c,m,caseId);
    else throw fail(400,'Выберите дело или документ');
    const responsible=uuid(b.responsible_id||req.user.id);
    await targetMember(c,responsible,caseId);
    const row=(await c.query(`INSERT INTO legal.tasks(organization_id,case_id,document_id,title,responsible_id,due_at,created_by)
      VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`,[ORG,caseId,b.document_id?uuid(b.document_id):null,text(b.title,300,true),responsible,date(b.due_at),req.user.id])).rows[0];
    await audit(c,req.user,'task.created','task',row.id,caseId);
    await notify(c,responsible,'В кабинете юриста назначена задача','Подробности доступны в кабинете.',req.user.id);
    return row;
  }));
  router.patch('/tasks/:id',route(async(c,req)=>{
    const m=await member(c,req.user,true),s=scope(m,'t','case_id',2);
    const row=(await c.query(`SELECT t.* FROM legal.tasks t WHERE t.id=$1 AND t.organization_id='${ORG}' AND ${s.sql} FOR UPDATE`,[uuid(req.params.id),...s.params])).rows[0];
    if(!row) throw fail(404,'Задача не найдена');
    revision(row,req.body.revision);
    const b=req.body,status=choice(b.status||row.status,['open','done','cancelled']);
    const responsible=b.responsible_id?uuid(b.responsible_id):row.responsible_id;
    await targetMember(c,responsible,row.case_id);
    const result=(await c.query(`UPDATE legal.tasks SET status=$2,result=$3,responsible_id=$4,due_at=$5,revision=revision+1,
      reminded_at=CASE WHEN due_at<>$5::timestamptz THEN NULL ELSE reminded_at END WHERE id=$1 RETURNING *`,
      [row.id,status,text(b.result,3000),responsible,b.due_at?date(b.due_at):row.due_at])).rows[0];
    await audit(c,req.user,'task.updated','task',row.id,row.case_id,{status});return result;
  }));
  router.get('/audit',route(async(c,req)=>{
    const m=await member(c,req.user),s=scope(m,'a','case_id');
    return (await c.query(`SELECT a.*,p.username AS actor_name FROM legal.audit_events a LEFT JOIN public.profiles p ON p.user_id=a.actor_id
      WHERE a.organization_id='${ORG}' AND ${s.sql} ORDER BY a.created_at DESC LIMIT 300`,s.params)).rows;
  }));
}
