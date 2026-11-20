import { pool } from '../db.js';
import { readSessionVersion } from '../security/session-version.js';

export async function standaloneMaxAccount(maxId, ownerId = null) {
  const { rows: [account] } = await pool.query(
    `SELECT u.id, CASE WHEN u.email_confirmed_at IS NOT NULL THEN u.email END AS email, u.raw_user_meta_data
     FROM public.max_chat_profiles m JOIN auth.users u ON u.id=m.user_id
     WHERE m.max_id=$1 AND ($2::uuid IS NULL OR u.id=$2)
       AND NOT (u.raw_user_meta_data ? 'deleted_at')`, [maxId, ownerId],
  );
  return account ? { ...account, mode: 'max' } : null;
}

export async function ensureStandaloneMaxAccount(maxId) {
  const existing = await standaloneMaxAccount(maxId);
  if (existing) return existing;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`max-profile:${maxId}`]);
    const { rows: [prior] } = await client.query(
      `SELECT u.id, CASE WHEN u.email_confirmed_at IS NOT NULL THEN u.email END AS email, u.raw_user_meta_data FROM public.max_chat_profiles m
       JOIN auth.users u ON u.id=m.user_id WHERE m.max_id=$1`, [maxId],
    );
    if (prior?.raw_user_meta_data?.deleted_at) {
      await client.query('COMMIT');
      return null;
    }
    let account = prior;
    if (!account) {
      const result = await client.query(
        `INSERT INTO auth.users (raw_user_meta_data)
         VALUES (jsonb_build_object('registration_source','max','max_only',true,'session_version',0))
         RETURNING id,email,raw_user_meta_data`,
      );
      [account] = result.rows;
      const profile = await client.query('SELECT 1 FROM public.profiles WHERE user_id=$1', [account.id]);
      if (!profile.rowCount) throw new Error('MAX profile was not initialized');
      await client.query('INSERT INTO public.max_chat_profiles(max_id,user_id) VALUES($1,$2)', [maxId, account.id]);
    }
    await client.query('COMMIT');
    return { ...account, mode: 'max' };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

export async function linkedMaxAccount(maxId, ownerId = null) {
  const { rows: [account] } = await pool.query(
    `SELECT u.id, u.email, u.raw_user_meta_data, l.session_version AS linked_version, l.active
     FROM public.max_chat_accounts l JOIN auth.users u ON u.id=l.user_id
     WHERE l.max_id=$1 AND ($2::uuid IS NULL OR u.id=$2) AND u.email_confirmed_at IS NOT NULL
       AND NOT (u.raw_user_meta_data ? 'deleted_at')`, [maxId, ownerId],
  );
  return account && readSessionVersion(account) === account.linked_version ? { ...account, mode: 'site' } : null;
}

export async function selectMaxMode(maxId, mode) {
  if (mode === 'max' && !(await ensureStandaloneMaxAccount(maxId))) return false;
  if (mode === 'site' && !(await linkedMaxAccount(maxId))) return false;
  await pool.query('UPDATE public.max_chat_accounts SET active=$2 WHERE max_id=$1', [maxId, mode === 'site']);
  return true;
}

export async function maxAccount(maxId, ownerId) {
  const linked = await linkedMaxAccount(maxId, ownerId);
  if (ownerId) {
    return linked ?? standaloneMaxAccount(maxId, ownerId);
  }
  const account = linked?.active ? linked : await ensureStandaloneMaxAccount(maxId);
  return account ? { ...account, siteLinked: Boolean(linked) } : null;
}
