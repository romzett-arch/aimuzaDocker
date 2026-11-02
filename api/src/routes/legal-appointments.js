import { ORG,route,actor,manager,administrativeAccess,audit,notify,uuid,text,choice,date,fail } from '../services/legal/core.js';

export function appointments(router) {
  router.get('/me',route(async(c,req)=>{
    await actor(c,req.user);
    const permanent=await administrativeAccess(c,req.user);
    const membership=permanent||(await c.query(`SELECT * FROM legal.memberships WHERE organization_id=$1 AND user_id=$2
      AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>now())`,[ORG,req.user.id])).rows[0]||null;
    const pending=(await c.query(`SELECT a.*,p.username AS appointed_by_name FROM legal.appointments a
      LEFT JOIN public.profiles p ON p.user_id=a.appointed_by WHERE a.organization_id=$1 AND a.user_id=$2
      AND a.status='pending' AND a.expires_at>now() AND (a.access_expires_at IS NULL OR a.access_expires_at>now())`,[ORG,req.user.id])).rows;
    const canManage=(await c.query("SELECT 1 FROM public.user_roles WHERE user_id=$1 AND role::text IN ('admin','super_admin')",[req.user.id])).rowCount>0;
    return {membership,appointments:permanent?[]:pending,canManage};
  }));
  router.get('/management',route(async(c,req)=>{
    await manager(c,req.user);
    const members=(await c.query(`SELECT m.*,p.username FROM legal.memberships m LEFT JOIN public.profiles p ON p.user_id=m.user_id WHERE organization_id=$1 ORDER BY m.created_at DESC`,[ORG])).rows;
    const pending=(await c.query(`SELECT a.*,p.username FROM legal.appointments a LEFT JOIN public.profiles p ON p.user_id=a.user_id WHERE organization_id=$1 ORDER BY a.created_at DESC LIMIT 200`,[ORG])).rows;
    // Access managers see only case identifiers/titles needed to assign scope; no contents.
    const cases=(await c.query('SELECT id,title FROM legal.cases WHERE organization_id=$1 ORDER BY title',[ORG])).rows;
    return {members,appointments:pending,cases};
  }));
  router.get('/management/users',route(async(c,req)=>{
    await manager(c,req.user);
    const q=text(req.query.q,100);
    return (await c.query(`SELECT p.user_id,p.username FROM public.profiles p JOIN auth.users u ON u.id=p.user_id
      WHERE u.email_confirmed_at IS NOT NULL AND (p.username ILIKE $1 OR p.user_id::text=$2) ORDER BY p.username LIMIT 30`,['%'+q+'%',q])).rows;
  }));
  router.post('/appointments',route(async(c,req)=>{
    await manager(c,req.user);
    const b=req.body, userId=uuid(b.user_id), profile=choice(b.profile||'lawyer',['lawyer','viewer']);
    if(await administrativeAccess(c,{id:userId}))throw fail(409,'Администратор и Технический специалист уже имеют постоянный доступ к кабинету');
    const selectedScope=choice(b.scope,['all','cases']);
    if (!Array.isArray(b.case_ids||[]) || (b.case_ids||[]).length>100) throw fail(400,'Некорректный список дел');
    const ids=[...new Set((b.case_ids||[]).map(uuid))];
    if (selectedScope==='cases' && !ids.length) throw fail(400,'Выберите хотя бы одно дело');
    const valid=await c.query('SELECT id FROM legal.cases WHERE organization_id=$1 AND id=ANY($2::uuid[])',[ORG,ids]);
    if(valid.rowCount!==ids.length) throw fail(400,'Дело не найдено');
    const expires=date(b.access_expires_at,true);
    if (expires && Date.parse(expires)<=Date.now()) throw fail(400,'Срок доступа должен быть в будущем');
    const user=await c.query('SELECT id FROM auth.users WHERE id=$1 AND email_confirmed_at IS NOT NULL',[userId]);
    if(!user.rowCount) throw fail(400,'Пользователь не найден или email не подтверждён');
    await c.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",['legal-member:'+userId]);
    await c.query(`UPDATE legal.appointments SET status='expired',responded_at=now() WHERE user_id=$1 AND status='pending' AND (expires_at<=now() OR access_expires_at<=now())`,[userId]);
    const a=(await c.query(`INSERT INTO legal.appointments(organization_id,user_id,appointed_by,profile,scope,case_ids,manage_templates,access_expires_at,message,reason)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *`,[ORG,userId,req.user.id,profile,selectedScope,ids,profile==='lawyer'&&b.manage_templates===true,expires,text(b.message,2000),text(b.reason,1000)])).rows[0];
    await audit(c,req.user,'appointment.created','appointment',a.id,null,{user_id:userId,profile,scope:selectedScope});
    await notify(c,userId,profile==='lawyer'?'Вас назначают Юристом АИМУЗА':'Вам назначают доступ наблюдателя', 'Откройте назначение: проверьте полномочия и примите его.',req.user.id);
    return a;
  }));
  router.post('/appointments/:id/respond',route(async(c,req)=>{
    await actor(c,req.user);
    if (typeof req.body.accept!=='boolean') throw fail(400,'Укажите решение');
    await c.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",['legal-member:'+req.user.id]);
    const a=(await c.query('SELECT * FROM legal.appointments WHERE id=$1 AND user_id=$2 FOR UPDATE',[uuid(req.params.id),req.user.id])).rows[0];
    if (!a) throw fail(404,'Назначение не найдено');
    if (a.status==='accepted' && req.body.accept) return {accepted:true};
    if(a.status!=='pending' || Date.parse(a.expires_at)<=Date.now() || (a.access_expires_at && Date.parse(a.access_expires_at)<=Date.now())) throw fail(409,'Назначение отменено или срок истёк');
    if(req.body.accept) await manager(c,{...req.user,id:a.appointed_by});
    if(req.body.accept) {
      await c.query(`INSERT INTO legal.memberships(organization_id,user_id,profile,scope,manage_templates,expires_at,granted_by)
        VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(organization_id,user_id) DO UPDATE SET profile=EXCLUDED.profile,scope=EXCLUDED.scope,
        manage_templates=EXCLUDED.manage_templates,expires_at=EXCLUDED.expires_at,granted_by=EXCLUDED.granted_by,revoked_at=NULL,expiry_notified_at=NULL,revision=legal.memberships.revision+1`,[ORG,req.user.id,a.profile,a.scope,a.manage_templates,a.access_expires_at,a.appointed_by]);
      await c.query('DELETE FROM legal.case_members WHERE organization_id=$1 AND user_id=$2',[ORG,req.user.id]);
      for(const id of a.case_ids) await c.query('INSERT INTO legal.case_members(organization_id,case_id,user_id) VALUES($1,$2,$3)',[ORG,id,req.user.id]);
      await notify(c,req.user.id,a.profile==='lawyer'?'Вы назначены Юристом АИМУЗА':'Доступ наблюдателя открыт','Кабинет юриста доступен для работы.',a.appointed_by);
    }
    await c.query('UPDATE legal.appointments SET status=$2,responded_at=now() WHERE id=$1',[a.id,req.body.accept?'accepted':'declined']);
    await audit(c,req.user,req.body.accept?'appointment.accepted':'appointment.declined','appointment',a.id);
    await notify(c,a.appointed_by,req.body.accept?'Назначение принято':'Назначение отклонено','Результат назначения доступен в управлении кабинетом.',req.user.id);
    return {accepted:req.body.accept};
  }));
  router.post('/appointments/:id/cancel',route(async(c,req)=>{
    await manager(c,req.user);
    const result=await c.query("UPDATE legal.appointments SET status='cancelled',responded_at=now() WHERE id=$1 AND organization_id=$2 AND status='pending' RETURNING *",[uuid(req.params.id),ORG]);
    if(!result.rowCount) throw fail(409,'Назначение уже обработано');
    await audit(c,req.user,'appointment.cancelled','appointment',req.params.id);
    await notify(c,result.rows[0].user_id,'Назначение в юридический кабинет отменено','',req.user.id);
    return {ok:true};
  }));
  router.post('/memberships/:id/revoke',route(async(c,req)=>{
    await manager(c,req.user);
    const reason=text(req.body.reason,1000,true);
    const m=(await c.query('SELECT * FROM legal.memberships WHERE id=$1 AND organization_id=$2',[uuid(req.params.id),ORG])).rows[0];
    if(!m) throw fail(404,'Назначение не найдено');
    if(await administrativeAccess(c,{id:m.user_id}))throw fail(409,'Постоянный доступ определяется системной ролью и не отзывается назначением юриста');
    await c.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",['legal-member:'+m.user_id]);
    await c.query('UPDATE legal.memberships SET revoked_at=now(),revision=revision+1 WHERE id=$1',[m.id]);
    await c.query("UPDATE legal.appointments SET status='cancelled',responded_at=now() WHERE user_id=$1 AND status='pending'",[m.user_id]);
    await audit(c,req.user,'membership.revoked','membership',m.id,null,{reason,user_id:m.user_id});
    await notify(c,m.user_id,'Ваш доступ к кабинету юриста отозван','Документы и история работы сохранены в АИМУЗА.',req.user.id);
    return {ok:true};
  }));
}
