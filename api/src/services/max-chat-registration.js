import { createHash } from 'node:crypto';
import { maxSignupCodeHash } from './max-chat-accounts.js';

// Upgrade the owner in place. The code is shown only in the original MAX chat.
export async function registerMaxWebsiteAccount(database, { registration, email, passwordHash, username }) {
  if (typeof registration?.link !== 'string' || !/^[a-f0-9]{64}$/.test(registration.link) ||
      typeof registration.code !== 'string' || !/^\d{8}$/.test(registration.code)) {
    return { code: 'INVALID_MAX_REGISTRATION' };
  }
  const linkHash = createHash('sha256').update(registration.link).digest('hex');
  const client = await database.connect();
  try {
    await client.query('BEGIN');
    const { rows: [challenge] } = await client.query(
      `UPDATE public.max_chat_challenges SET attempts=attempts+1
       WHERE link_hash=$1 AND expires_at>now() AND signup_code_hash IS NOT NULL
         AND code_hash IS NULL AND attempts<5
       RETURNING max_id,signup_code_hash`, [linkHash],
    );
    if (!challenge || challenge.signup_code_hash !== maxSignupCodeHash(linkHash, registration.code)) {
      await client.query('COMMIT');
      return { code: 'INVALID_MAX_REGISTRATION' };
    }

    await client.query('SELECT pg_advisory_xact_lock(hashtextextended(lower($1),0))', ['nickname:' + username]);
    const { rows: [account] } = await client.query(
      `SELECT u.id, u.email FROM public.max_chat_profiles m JOIN auth.users u ON u.id=m.user_id
       WHERE m.max_id=$1 AND u.email_confirmed_at IS NULL AND u.raw_user_meta_data->>'max_only'='true'
         AND NOT (u.raw_user_meta_data ? 'deleted_at') FOR UPDATE OF u`, [challenge.max_id],
    );
    if (!account) {
      await client.query('ROLLBACK');
      return { code: 'INVALID_MAX_REGISTRATION' };
    }
    const nameTaken = await client.query('SELECT 1 FROM public.profiles WHERE lower(username)=lower($1) AND user_id<>$2', [username, account.id]);
    if (nameTaken.rowCount) {
      await client.query('ROLLBACK');
      return { code: 'NICKNAME_TAKEN' };
    }
    const result = await client.query(
      `UPDATE auth.users SET email=$2, encrypted_password=$3, updated_at=now(),
         raw_user_meta_data=raw_user_meta_data || jsonb_build_object('username',$4::text,'display_name',$4::text)
       WHERE id=$1 RETURNING id,email,created_at`,
      [account.id, email, passwordHash, username],
    );
    await client.query('UPDATE public.profiles SET email=$2,username=$3,display_name=$3 WHERE user_id=$1', [account.id, email, username]);
    if (account.email) await client.query('DELETE FROM public.email_verifications WHERE email=$1', [account.email]);
    await client.query('UPDATE public.max_chat_challenges SET signup_code_hash=NULL,attempts=0 WHERE link_hash=$1', [linkHash]);
    await client.query('COMMIT');
    return { user: result.rows[0] };
  } catch (error) {
    await client.query('ROLLBACK');
    if (error.code === '23505') return { code: 'EMAIL_IN_USE' };
    throw error;
  } finally {
    client.release();
  }
}
