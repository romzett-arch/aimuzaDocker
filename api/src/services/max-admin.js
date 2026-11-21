import { pool } from '../db.js';

export const validMaxId = id => typeof id === 'string' && /^[1-9][0-9]{0,18}$/.test(id);

export async function isMaxBlocked(maxId) {
  const result = await pool.query('SELECT 1 FROM public.max_chat_blocks WHERE max_id=$1', [maxId]);
  return result.rowCount > 0;
}

const accounts = `
  SELECT COALESCE(m.max_id,l.max_id) AS max_id, member.id AS user_id,
         m.max_display_name AS name, m.last_interaction_at, member.created_at AS started_at,
         profile.username, profile.balance,
         website.user_id AS site_user_id, website.username AS site_username, website.display_name AS site_name,
         COALESCE(member.created_at, site.created_at) AS created_at, member.id IS NOT NULL AS registered,
         site.id IS NOT NULL AS linked, site.id IS NOT NULL AND l.active AS using_site,
         b.blocked_at
  FROM public.max_chat_profiles m FULL JOIN public.max_chat_accounts l USING (max_id)
  LEFT JOIN auth.users member ON member.id=m.user_id AND NOT (COALESCE(member.raw_user_meta_data,'{}') ? 'deleted_at')
  LEFT JOIN auth.users site ON site.id=l.user_id AND NOT (COALESCE(site.raw_user_meta_data,'{}') ? 'deleted_at')
    AND site.email_confirmed_at IS NOT NULL
    AND (CASE WHEN COALESCE(site.raw_user_meta_data->>'session_version','') ~ '^[0-9]+$'
         THEN (site.raw_user_meta_data->>'session_version')::integer ELSE 0 END) = l.session_version
  LEFT JOIN public.profiles profile ON profile.user_id=COALESCE(member.id, site.id)
  LEFT JOIN public.profiles website ON website.user_id=COALESCE(site.id, CASE WHEN member.email_confirmed_at IS NOT NULL THEN member.id END)
  LEFT JOIN public.max_chat_blocks b ON b.max_id=COALESCE(m.max_id,l.max_id)
  WHERE member.id IS NOT NULL OR site.id IS NOT NULL`;

export async function maxAdminList({ search, filter, offset }) {
  const [stats, users] = await Promise.all([
    pool.query(`SELECT count(*)::int AS users, count(*) FILTER (WHERE linked)::int AS linked,
      count(*) FILTER (WHERE blocked_at IS NOT NULL)::int AS blocked,
      count(*) FILTER (WHERE site_user_id IS NULL)::int AS max_only,
      count(*) FILTER (WHERE registered AND created_at >= now()-interval '30 days')::int AS new_users
      FROM (${accounts}) AS accounts`),
    pool.query(`SELECT * FROM (${accounts}) AS accounts
      WHERE ($1 = '' OR position(lower($1) in lower(concat_ws(' ',max_id,user_id,name,username,site_username,site_name))) > 0)
        AND ($2 = 'all' OR ($2 = 'linked' AND linked) OR ($2 = 'max_only' AND site_user_id IS NULL)
             OR ($2 = 'blocked' AND blocked_at IS NOT NULL))
      ORDER BY created_at DESC NULLS LAST, max_id DESC LIMIT 26 OFFSET $3`, [search, filter, offset]),
  ]);
  return { stats: stats.rows[0], users: users.rows.slice(0, 25), more: users.rows.length > 25 };
}

export async function setMaxBlocked(maxId, blocked, adminId) {
  if (!blocked) {
    const result = await pool.query('DELETE FROM public.max_chat_blocks WHERE max_id=$1', [maxId]);
    return result.rowCount > 0;
  }
  const result = await pool.query(`INSERT INTO public.max_chat_blocks(max_id,blocked_by)
    SELECT max_id,$2 FROM (${accounts}) AS accounts WHERE max_id=$1
    ON CONFLICT (max_id) DO UPDATE SET blocked_by=COALESCE(max_chat_blocks.blocked_by,EXCLUDED.blocked_by)
    RETURNING max_id`, [maxId, adminId]);
  return result.rowCount > 0;
}
