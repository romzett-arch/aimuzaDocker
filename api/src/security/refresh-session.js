import crypto from 'node:crypto';
const digest=token=>crypto.createHash('sha256').update(token).digest('hex');
export async function issueRefresh(client,user) {
  const token=crypto.randomBytes(32).toString('hex');
  await client.query(`INSERT INTO public.api_refresh_sessions(token_hash,user_id,session_version,expires_at) VALUES($1,$2,$3,now()+interval '30 days')`,[digest(token),user.id,Number(user.raw_user_meta_data?.session_version??user.session_version??0)]);
  return token;
}
export async function consumeRefresh(client,token) {
  if (typeof token!=='string' || !/^[a-f0-9]{64}$/.test(token)) return null;
  const {rows}=await client.query(`DELETE FROM public.api_refresh_sessions WHERE token_hash=$1 AND expires_at>now() RETURNING user_id,session_version`,[digest(token)]);
  if (!rows.length) return null;
  const result=await client.query(`SELECT id,email,created_at,raw_user_meta_data FROM auth.users WHERE id=$1 AND email_confirmed_at IS NOT NULL AND COALESCE(raw_user_meta_data->>'session_version','0')=$2`,[rows[0].user_id,String(rows[0].session_version)]);
  return result.rows[0]||null;
}
export async function freshRoles(client,user) {
  const {rows}=await client.query(`SELECT role::text AS role FROM public.user_roles WHERE user_id=$1 ORDER BY CASE role::text WHEN 'super_admin' THEN 0 WHEN 'admin' THEN 1 WHEN 'moderator' THEN 2 ELSE 3 END LIMIT 1`,[user.id]);
  return {...user,app_role:rows[0]?.role||'user',is_super_admin:rows[0]?.role==='super_admin'};
}
