import { createHash, randomBytes, randomInt } from 'node:crypto';
import { pool } from '../db.js';
import { readSessionVersion } from '../security/session-version.js';

const challengeLimit = 5;
const digest = (value) => createHash('sha256').update(value).digest('hex');

export const maxSignupCodeHash = (linkHash, code) => digest(`signup:${linkHash}:${code}`);

export async function issueMaxLink(maxId, allowSignup) {
  const link = randomBytes(32).toString('hex');
  const linkHash = digest(link);
  const signupCode = allowSignup ? String(randomInt(100_000_000)).padStart(8, '0') : null;
  await pool.query('DELETE FROM public.max_chat_challenges WHERE expires_at < now()');
  await pool.query(
    `INSERT INTO public.max_chat_challenges(link_hash,max_id,signup_code_hash,expires_at)
     VALUES($1,$2,$3,now()+interval '10 minutes')
     ON CONFLICT (max_id) DO UPDATE SET link_hash=EXCLUDED.link_hash, expires_at=EXCLUDED.expires_at,
       user_id=NULL, session_version=NULL, code_hash=NULL, attempts=0, signup_code_hash=EXCLUDED.signup_code_hash`,
    [linkHash, maxId, signupCode && maxSignupCodeHash(linkHash, signupCode)],
  );
  return { link, signupCode };
}

export async function prepareMaxConfirmation(link, user) {
  const code = String(randomInt(100_000_000)).padStart(8, '0');
  const linkHash = digest(link);
  const result = await pool.query(
    `UPDATE public.max_chat_challenges SET user_id=$2,session_version=$3,code_hash=$4
     WHERE link_hash=$1 AND expires_at>now() AND user_id IS NULL`,
    [linkHash, user.id, user.session_version, digest(linkHash + code)],
  );
  return result.rowCount ? code : null;
}

export async function confirmMaxAccount(maxId, code) {
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const { rows: [challenge] } = await db.query(
      `UPDATE public.max_chat_challenges SET attempts=attempts+1
       WHERE max_id=$1 AND expires_at>now() AND code_hash IS NOT NULL AND attempts<$2
       RETURNING *`, [maxId, challengeLimit],
    );
    if (!challenge || challenge.code_hash !== digest(challenge.link_hash + code)) {
      await db.query('COMMIT');
      return false;
    }
    const { rows: [user] } = await db.query(
      'SELECT raw_user_meta_data FROM auth.users WHERE id=$1 AND email_confirmed_at IS NOT NULL', [challenge.user_id],
    );
    if (!user || readSessionVersion(user) !== challenge.session_version) {
      await db.query('DELETE FROM public.max_chat_challenges WHERE max_id=$1', [maxId]);
      await db.query('COMMIT');
      return false;
    }
    await db.query('SELECT pg_advisory_xact_lock(hashtext($1))', [challenge.user_id]);
    const { rows } = await db.query('SELECT max_id,user_id FROM public.max_chat_accounts WHERE max_id=$1 OR user_id=$2', [maxId, challenge.user_id]);
    const allowed = rows.every(row => row.max_id === maxId && row.user_id === challenge.user_id);
    if (allowed) {
      await db.query(
        `INSERT INTO public.max_chat_accounts(max_id,user_id,session_version) VALUES($1,$2,$3)
         ON CONFLICT(max_id) DO UPDATE SET session_version=EXCLUDED.session_version, active=true
         WHERE max_chat_accounts.user_id=EXCLUDED.user_id`,
        [maxId, challenge.user_id, challenge.session_version],
      );
    }
    await db.query('DELETE FROM public.max_chat_challenges WHERE max_id=$1', [maxId]);
    await db.query('COMMIT');
    return allowed;
  } catch (error) {
    await db.query('ROLLBACK');
    throw error;
  } finally { db.release(); }
}

export async function unlinkMaxAccount(maxId) {
  await pool.query('DELETE FROM public.max_chat_challenges WHERE max_id=$1', [maxId]);
  await pool.query('DELETE FROM public.max_chat_accounts WHERE max_id=$1', [maxId]);
}
