import { pool } from '../db.js';
import { consumeEmailCode } from './auth-mailer.js';

export async function verifySignupEmail(email, code) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Serialize verification for the same address before consuming its OTP.
    await client.query('SELECT id FROM auth.users WHERE email = $1 FOR UPDATE', [email]);
    if (!await consumeEmailCode(email, code, client)) {
      await client.query('ROLLBACK');
      return null;
    }
    const { rows: [confirmed] } = await client.query(
      `UPDATE auth.users SET email_confirmed_at = now(), updated_at = now()
       WHERE email = $1 AND email_confirmed_at IS NULL
       RETURNING raw_user_meta_data->>'signup_promo_status' AS promo_status`,
      [email],
    );
    await client.query('COMMIT');
    return { promoStatus: confirmed?.promo_status ?? undefined };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
