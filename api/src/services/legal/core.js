import crypto from 'node:crypto';
import { pool } from '../../db.js';

export const ORG = 'a1000000-0000-4000-8000-000000000001';
export const fail = (status, message, code = 'LEGAL_ERROR') => Object.assign(new Error(message), { status, code });
export const uuid = value => {
  if (typeof value !== 'string' || !/^[a-f\d]{8}(-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(value)) throw fail(400,'Некорректный идентификатор');
  return value;
};
export function text(value, max=300, required=false) {
  if (value == null && !required) return '';
  if (typeof value !== 'string' || value.length>max || (required && !value.trim())) throw fail(400,'Проверьте заполненные поля');
  return value.trim();
}
export function choice(value, values) {
  if (!values.includes(value)) throw fail(400,'Недопустимое значение');
  return value;
}
export function date(value, optional=false) {
  if (!value && optional) return null;
  if (typeof value!=='string' || !Number.isFinite(Date.parse(value))) throw fail(400,'Некорректная дата');
  return new Date(value).toISOString();
}
export function revision(row, expected) {
  if (!Number.isInteger(expected) || row.revision!==expected) throw fail(409,'Документ изменён. Обновите страницу и повторите действие.','LEGAL_REVISION_CONFLICT');
}
export function direct(user) {
  if (!user?.id || user.role==='service_role') throw fail(401,'Войдите в свой аккаунт');
  if (user.session_origin!=='direct') throw fail(403,'Для кабинета юриста войдите в свой аккаунт заново. Вход от имени пользователя недоступен.','LEGAL_DIRECT_SESSION_REQUIRED');
}
export async function actor(client, user) {
  direct(user);
  const {rows}=await client.query(`SELECT id FROM auth.users WHERE id=$1 AND email_confirmed_at IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=$1 AND b.is_active AND b.unblocked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at>now()))`,[user.id]);
  if (!rows.length) throw fail(403,'Учётная запись недоступна');
}
export async function manager(client, user) {
  await actor(client,user);
  const {rows}=await client.query("SELECT 1 FROM public.user_roles WHERE user_id=$1 AND role::text IN ('admin','super_admin')",[user.id]);
  if (!rows.length) throw fail(403,'Назначать юристов могут Администратор и Технический специалист');
}
export async function administrativeAccess(client,user) {
  const {rows}=await client.query(`SELECT r.role::text AS role FROM public.user_roles r JOIN auth.users u ON u.id=r.user_id
    WHERE r.user_id=$1 AND r.role::text IN ('admin','super_admin') AND u.email_confirmed_at IS NOT NULL
    AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=u.id AND b.is_active AND b.unblocked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at>now()))`,[user.id]);
  if(!rows.length)return null;
  return {id:'system-role:'+user.id,organization_id:ORG,user_id:user.id,profile:'lawyer',scope:'all',
    manage_templates:true,expires_at:null,revoked_at:null,revision:0,access_source:'system_role',system_role:rows[0].role};
}
export async function member(client,user,write=false) {
  await actor(client,user);
  const permanent=await administrativeAccess(client,user);
  if(permanent)return permanent;
  const {rows}=await client.query(`SELECT * FROM legal.memberships WHERE organization_id=$1 AND user_id=$2
    AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>now()) FOR SHARE`,[ORG,user.id]);
  if (!rows.length) throw fail(403,'Доступ к кабинету юриста не назначен или истёк','LEGAL_MEMBERSHIP_REQUIRED');
  if (write && rows[0].profile!=='lawyer') throw fail(403,'Доступ только для чтения');
  return rows[0];
}
export function scope(m, alias='d', column='case_id', offset=1) {
  return m.scope==='all' ? {sql:'TRUE',params:[]} : {
    sql:`${alias}.${column} IN (SELECT case_id FROM legal.case_members WHERE organization_id='${ORG}' AND user_id=$${offset})`,params:[m.user_id]
  };
}
export async function caseAccess(c,m,id) {
  uuid(id);
  const s=scope(m,'d','id',2);
  const {rows}=await c.query(`SELECT d.* FROM legal.cases d WHERE d.id=$1 AND d.organization_id='${ORG}' AND ${s.sql}`,[id,...s.params]);
  if (!rows.length) throw fail(404,'Дело не найдено');
  return rows[0];
}
export async function document(c,m,id,lock=false) {
  uuid(id);
  const s=scope(m,'d','case_id',2);
  const {rows}=await c.query(`SELECT d.*,d.document_date::text AS document_date,d.received_at::text AS received_at FROM legal.documents d WHERE d.id=$1 AND d.organization_id='${ORG}' AND ${s.sql}${lock?' FOR UPDATE':''}`,[id,...s.params]);
  if (!rows.length) throw fail(404,'Документ не найден');
  return rows[0];
}
export async function targetMember(c,userId,caseId) {
  uuid(userId);
  if(await administrativeAccess(c,{id:userId}))return;
  const {rows}=await c.query(`SELECT m.* FROM legal.memberships m JOIN auth.users u ON u.id=m.user_id
   WHERE m.organization_id=$1 AND m.user_id=$2 AND m.revoked_at IS NULL AND u.email_confirmed_at IS NOT NULL
   AND (m.expires_at IS NULL OR m.expires_at>now())
   AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=u.id AND b.is_active AND b.unblocked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at>now())) FOR SHARE OF m`,[ORG,userId]);
  const m=rows[0];
  if (!m) throw fail(400,'Ответственный не имеет доступа к кабинету');
  if (m.scope!=='all') {
    if (!caseId) throw fail(400,'Ответственному недоступен документ без дела');
    await caseAccess(c,m,caseId);
  }
}
export async function audit(c,user,action,type,id=null,caseId=null,metadata={}) {
  await c.query(`INSERT INTO legal.audit_events(organization_id,actor_id,action,object_type,object_id,case_id,metadata)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[ORG,user?.id||null,action,type,id,caseId,metadata]);
}
export async function notify(c,userId,title,message='',actorId=null) {
  await c.query(`INSERT INTO public.notifications(user_id,type,title,message,actor_id,link) VALUES($1,'system',$2,$3,$4,'/legal')`,[userId,title,message,actorId]);
}
export async function snapshot(c,user,doc,extra={}) {
  const files=(await c.query('SELECT id,name,sha256,purpose FROM legal.files WHERE document_id=$1 AND attached ORDER BY id',[doc.id])).rows;
  return (await c.query(`INSERT INTO legal.document_versions(organization_id,document_id,revision,snapshot,created_by)
    VALUES($1,$2,$3,$4,$5) RETURNING *`,[ORG,doc.id,doc.revision,{...doc,files,...extra},user.id])).rows[0];
}
export const hash = data => crypto.createHash('sha256').update(typeof data==='string'||Buffer.isBuffer(data)?data:JSON.stringify(data)).digest('hex');
export const route = handler => async(req,res,next) => {
  const c=await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query("SET LOCAL statement_timeout='15s'");
    const result=await handler(c,req,res);
    if(!res.locals.legalCommitted) await c.query('COMMIT');
    if (!res.headersSent && result!==undefined) res.json(result);
  } catch(error) {
    await c.query('ROLLBACK').catch(()=>{});
    if (error.code==='23505') return next(fail(409,'Такая запись уже существует. Обновите страницу.'));
    if (error.code==='23503') return next(fail(400,'Связанный объект не найден'));
    next(error);
  } finally {c.release();}
};
