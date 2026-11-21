import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { PASSWORD_POLICY_MESSAGE, validatePassword } from '../security/password.js';
import { normalizeNickname } from '../security/profile-onboarding.js';
import { readSessionVersion } from '../security/session-version.js';
import { consumeEmailCode, issueEmailCode, sendWelcomeEmail } from './auth-mailer.js';

const BCRYPT_ROUNDS = 12;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const CODE_RE = /^[A-Z0-9]{6}$/;
// Куда вводить код в письме, когда регистрацию завершают в чате MAX.
const MAX_INSTRUCTION = 'Пришли этот код боту AIMUZA в MAX личным сообщением:';

export const passwordPolicyMessage = PASSWORD_POLICY_MESSAGE;

// Шаг 1 мастера привязки: по почте решает — вход существующим аккаунтом или создание нового.
export async function startMaxAuth(maxId, rawEmail) {
  const email = String(rawEmail || '').toLowerCase().trim();
  if (!EMAIL_RE.test(email)) return { code: 'BAD_EMAIL' };
  const { rows: [existing] } = await pool.query(
    `SELECT id, email_confirmed_at FROM auth.users
     WHERE lower(email)=$1 AND NOT (raw_user_meta_data ? 'deleted_at')`, [email],
  );
  if (!existing) return { mode: 'signup' };
  if (!existing.email_confirmed_at) {
    const { rows: [own] } = await pool.query(
      'SELECT 1 FROM public.max_chat_profiles WHERE max_id=$1 AND user_id=$2', [String(maxId), existing.id],
    );
    if (!own) return { code: 'EMAIL_IN_USE' };
    // Незавершённая регистрация этого же MAX: почта и пароль уже сохранены.
    await issueEmailCode(email, { instruction: MAX_INSTRUCTION });
    return { mode: 'signup', resumed: true };
  }
  const { rows: [linked] } = await pool.query(
    'SELECT max_id FROM public.max_chat_accounts WHERE user_id=$1', [existing.id],
  );
  if (linked && linked.max_id !== String(maxId)) return { code: 'ALREADY_LINKED' };
  await issueEmailCode(email, { instruction: MAX_INSTRUCTION });
  return { mode: 'login' };
}

// Шаг 2 мастера (новый аккаунт): добавляет к профилю MAX почту, пароль и никнейм, шлёт код.
export async function registerMaxChatAccount(maxId, { email: rawEmail, password, username: rawUsername }) {
  const email = String(rawEmail || '').toLowerCase().trim();
  if (!EMAIL_RE.test(email)) return { code: 'BAD_EMAIL' };
  if (!validatePassword(password)) return { code: 'WEAK_PASSWORD', message: PASSWORD_POLICY_MESSAGE };
  const username = normalizeNickname(rawUsername);
  if (!username) return { code: 'BAD_NICKNAME' };
  const hashed = await bcrypt.hash(String(password), BCRYPT_ROUNDS);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended(lower($1),0))', ['nickname:' + username]);
    const { rows: [account] } = await client.query(
      `SELECT u.id, u.email FROM public.max_chat_profiles m JOIN auth.users u ON u.id=m.user_id
       WHERE m.max_id=$1 AND u.email_confirmed_at IS NULL AND u.raw_user_meta_data->>'max_only'='true'
         AND NOT (u.raw_user_meta_data ? 'deleted_at') FOR UPDATE OF u`, [String(maxId)],
    );
    if (!account) {
      await client.query('ROLLBACK');
      return { code: 'PROFILE_GONE' };
    }
    const nameTaken = await client.query(
      'SELECT 1 FROM public.profiles WHERE lower(username)=lower($1) AND user_id<>$2', [username, account.id],
    );
    if (nameTaken.rowCount) {
      await client.query('ROLLBACK');
      return { code: 'NICKNAME_TAKEN' };
    }
    await client.query(
      `UPDATE auth.users SET email=$2, encrypted_password=$3, updated_at=now(),
         raw_user_meta_data=raw_user_meta_data || jsonb_build_object('username',$4::text,'display_name',$4::text)
       WHERE id=$1`, [account.id, email, hashed, username],
    );
    await client.query('UPDATE public.profiles SET email=$2,username=$3,display_name=$3 WHERE user_id=$1', [account.id, email, username]);
    if (account.email) await client.query('DELETE FROM public.email_verifications WHERE email=$1', [account.email]);
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    if (error.code === '23505') return { code: 'EMAIL_IN_USE' };
    throw error;
  } finally {
    client.release();
  }
  await issueEmailCode(email, { username, instruction: MAX_INSTRUCTION });
  return { mode: 'signup' };
}

// Шаг 3 мастера: проверяет код из письма и завершает привязку MAX ↔ аккаунт сайта.
export async function verifyMaxAuth(maxId, { email: rawEmail, code }) {
  const email = String(rawEmail || '').toLowerCase().trim();
  const normalized = String(code || '').toUpperCase().trim();
  if (!EMAIL_RE.test(email) || !CODE_RE.test(normalized)) return { code: 'BAD_CODE' };
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const matched = await consumeEmailCode(email, normalized, db);
    if (!matched) {
      await db.query('ROLLBACK');
      return { code: 'BAD_CODE' };
    }
    const { rows: [user] } = await db.query(
      `SELECT id, raw_user_meta_data, email_confirmed_at FROM auth.users
       WHERE lower(email)=$1 AND NOT (raw_user_meta_data ? 'deleted_at') FOR UPDATE`, [email],
    );
    if (!user) {
      await db.query('ROLLBACK');
      return { code: 'PROFILE_GONE' };
    }
    const { rows: [own] } = await db.query(
      'SELECT 1 FROM public.max_chat_profiles WHERE max_id=$1 AND user_id=$2', [String(maxId), user.id],
    );
    const signupCompletion = Boolean(own) && !user.email_confirmed_at;
    if (!signupCompletion && !user.email_confirmed_at) {
      await db.query('ROLLBACK');
      return { code: 'BAD_CODE' };
    }
    const { rows: [linked] } = await db.query(
      'SELECT max_id FROM public.max_chat_accounts WHERE user_id=$1', [user.id],
    );
    if (linked && linked.max_id !== String(maxId)) {
      await db.query('ROLLBACK');
      return { code: 'ALREADY_LINKED' };
    }
    if (signupCompletion) {
      await db.query('UPDATE auth.users SET email_confirmed_at=COALESCE(email_confirmed_at,now()),updated_at=now() WHERE id=$1', [user.id]);
    }
    await db.query(
      `INSERT INTO public.max_chat_accounts(max_id,user_id,session_version,active)
       VALUES($1,$2,$3,true)
       ON CONFLICT(max_id) DO UPDATE SET user_id=EXCLUDED.user_id,
         session_version=EXCLUDED.session_version, active=true`, [String(maxId), user.id, readSessionVersion(user)],
    );
    await db.query('COMMIT');
    if (signupCompletion) {
      const { rows: [profile] } = await pool.query('SELECT username FROM public.profiles WHERE user_id=$1', [user.id]);
      await sendWelcomeEmail(email, profile?.username);
    }
    return { ok: true, mode: signupCompletion ? 'signup' : 'login' };
  } catch (error) {
    await db.query('ROLLBACK');
    throw error;
  } finally { db.release(); }
}

export async function unlinkMaxAccount(maxId) {
  await pool.query('DELETE FROM public.max_chat_challenges WHERE max_id=$1', [maxId]);
  await pool.query('DELETE FROM public.max_chat_accounts WHERE max_id=$1', [maxId]);
}
