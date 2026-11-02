import fs from 'node:fs/promises';
import { pool } from '../../db.js';
import { ORG,hash,audit,notify } from './core.js';
import { ROOT,filePath } from './file-rules.js';
import { makePdf } from './pdf.js';
import { scanBuffer } from './scanner.js';
import { cleanupUnlinkedFiles } from './cleanup.js';

let running=false;
async function claim() {
  return (await pool.query(`UPDATE legal.jobs SET status='running',attempts=attempts+1,lease_until=now()+interval '3 minutes'
    WHERE id=(SELECT id FROM legal.jobs WHERE ((status='pending' AND available_at<=now()) OR (status='running' AND lease_until<now()))
    AND attempts<8 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *`)).rows[0];
}
async function perform(job) {
  let buffer,file,clean=true;
  if(job.type==='scan') {
    file=(await pool.query('SELECT * FROM legal.files WHERE id=$1',[job.file_id])).rows[0];
    if(!file) throw new Error('FILE_NOT_FOUND');
    buffer=await fs.readFile(filePath(file.storage_key));
    if(hash(buffer)!==file.sha256) throw new Error('FILE_INTEGRITY_FAILED');
    clean=await scanBuffer(buffer);
  } else {
    const entry=(await pool.query(`SELECT v.snapshot,r.registered_at FROM legal.register_entries r JOIN legal.document_versions v ON v.id=r.version_id WHERE r.document_id=$1`,[job.document_id])).rows[0];
    if(!entry) throw new Error('REGISTRATION_NOT_FOUND');
    buffer=await makePdf(entry.snapshot,entry.registered_at);
  }
  const c=await pool.connect();
  try {
    await c.query('BEGIN');
    const owned=await c.query("SELECT id FROM legal.jobs WHERE id=$1 AND status='running' AND attempts=$2 AND lease_until>now() FOR UPDATE",[job.id,job.attempts]);
    if(!owned.rowCount) {await c.query('ROLLBACK');return;}
    const d=(await c.query('SELECT * FROM legal.documents WHERE id=$1',[job.document_id])).rows[0];
    if(job.type==='scan') await c.query('UPDATE legal.files SET status=$2 WHERE id=$1',[file.id,clean?'ready':'rejected']);
    else {
      const org=(await c.query('SELECT quota_bytes FROM legal.organizations WHERE id=$1 FOR UPDATE',[ORG])).rows[0];
      const used=Number((await c.query('SELECT COALESCE(sum(size),0) AS size FROM legal.files WHERE organization_id=$1',[ORG])).rows[0].size);
      if(used+buffer.length>Number(org.quota_bytes)) throw new Error('STORAGE_QUOTA_EXCEEDED');
      await fs.mkdir(ROOT,{recursive:true});
      const tmp=filePath(job.id)+'.tmp';await fs.writeFile(tmp,buffer,{mode:0o600});await fs.rename(tmp,filePath(job.id));
      await c.query(`INSERT INTO legal.files(id,organization_id,document_id,name,storage_key,mime,size,sha256,purpose,status)
        VALUES($1,$2,$3,$4,$7,'application/pdf',$5,$6,'pdf','ready') ON CONFLICT(id) DO NOTHING`,[job.id,ORG,d.id,d.title.slice(0,150)+'.pdf',buffer.length,hash(buffer),job.id]);
    }
    await c.query("UPDATE legal.jobs SET status='ready',lease_until=NULL,last_error=NULL WHERE id=$1",[job.id]);
    await audit(c,null,job.type==='pdf'?'pdf.ready':clean?'file.checked':'file.rejected','document',d.id,d.case_id,{file_id:job.file_id});
    await c.query('COMMIT');
  } catch(error) {await c.query('ROLLBACK');throw error;}
  finally {c.release();}
}
async function reminders() {
  const c=await pool.connect();
  try {
    await c.query('BEGIN');
    const {rows}=await c.query(`SELECT t.* FROM legal.tasks t JOIN auth.users u ON u.id=t.responsible_id
      LEFT JOIN legal.memberships m ON m.user_id=t.responsible_id AND m.organization_id=t.organization_id
      WHERE t.status='open' AND t.reminded_at IS NULL AND t.due_at<=now()+interval '1 day' AND u.email_confirmed_at IS NOT NULL
      AND (EXISTS(SELECT 1 FROM public.user_roles r WHERE r.user_id=t.responsible_id AND r.role::text IN ('admin','super_admin'))
        OR (m.revoked_at IS NULL AND (m.expires_at IS NULL OR m.expires_at>now())
          AND (m.scope='all' OR EXISTS(SELECT 1 FROM legal.case_members cm WHERE cm.user_id=m.user_id AND cm.case_id=t.case_id))))
      AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=t.responsible_id AND b.is_active AND b.unblocked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at>now()))
      ORDER BY t.due_at FOR UPDATE OF t SKIP LOCKED LIMIT 20`);
    for(const t of rows) {
      await notify(c,t.responsible_id,'Приближается или наступил срок юридической задачи','Откройте кабинет юриста, чтобы проверить задачу.');
      await c.query('UPDATE legal.tasks SET reminded_at=now() WHERE id=$1',[t.id]);
    }
    await c.query(`UPDATE legal.appointments SET status='expired',responded_at=now() WHERE status='pending' AND (expires_at<=now() OR access_expires_at<=now())`);
    const expired=(await c.query(`UPDATE legal.memberships m SET expiry_notified_at=now() WHERE expires_at<=now() AND revoked_at IS NULL AND expiry_notified_at IS NULL
      AND NOT EXISTS(SELECT 1 FROM public.user_roles r WHERE r.user_id=m.user_id AND r.role::text IN ('admin','super_admin')) RETURNING user_id`)).rows;
    for(const m of expired) await notify(c,m.user_id,'Срок доступа к кабинету юриста истёк','Для продления обратитесь к Администратору или Техническому специалисту.');
    await c.query("UPDATE legal.jobs SET status='failed',last_error='RETRY_LIMIT_EXCEEDED' WHERE status='running' AND lease_until<now() AND attempts>=8");
    await c.query('COMMIT');
  } catch(error) {await c.query('ROLLBACK');throw error;}
  finally {c.release();}
}
export async function runLegalWorker() {
  if(running)return;running=true;
  try {
    const job=await claim();
    if(job) {
      try {await perform(job);}
      catch(error) {
        console.error('[Legal job]',error.code||error.message);
        const allowed=new Set(['SCANNER_UNAVAILABLE','SCANNER_TIMEOUT','SCANNER_FAILED','SCANNER_DISCONNECTED','FILE_INTEGRITY_FAILED','STORAGE_QUOTA_EXCEEDED']);
        const code=allowed.has(error.message)?error.message:'PROCESSING_FAILED';
        await pool.query(`UPDATE legal.jobs SET status=CASE WHEN attempts>=8 THEN 'failed' ELSE 'pending' END,
          available_at=now()+interval '30 seconds'*LEAST(attempts,8),last_error=$3,lease_until=NULL WHERE id=$1 AND attempts=$2 AND status='running'`,[job.id,job.attempts,code]);
      }
    }
    await reminders();
    await cleanupUnlinkedFiles(pool);
  } catch(error) {console.error('[Legal worker]',error.code||'FAILED');}
  finally {running=false;}
}
export function startLegalWorker() {void runLegalWorker();setInterval(()=>void runLegalWorker(),10000).unref();}
