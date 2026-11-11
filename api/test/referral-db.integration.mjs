// Run against the migrated local database. All fixtures roll back.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { pool } from '../src/db.js';
import { registerSignup } from '../src/routes/auth-signup.js';

const db = await pool.connect();
const balance = async (id) => Number((await db.query(
  'SELECT balance FROM public.profiles WHERE user_id=$1', [id],
)).rows[0].balance);
const referral = async (id) => (await db.query(
  'SELECT * FROM public.referrals WHERE referee_id=$1', [id],
)).rows[0];
const setting = (key, value) => db.query(
  'UPDATE public.referral_settings SET value=$2 WHERE key=$1', [key, value],
);

try {
  await db.query('BEGIN');
  const referrer = (await db.query(
    'INSERT INTO auth.users(email, email_confirmed_at) VALUES($1, now()) RETURNING id',
    [`referrer-${randomUUID()}@example.invalid`],
  )).rows[0].id;
  const code = randomUUID().slice(0, 8);
  await db.query('INSERT INTO public.referral_codes(user_id,code) VALUES($1,$2)', [referrer, code]);
  await setting('program_enabled', 'true');
  await setting('max_referrals_per_user', '1');
  await setting('min_deposit_to_activate', '100');

  let handler;
  registerSignup({ post: (_path, callback) => { handler = callback; } }, db);
  const signup = async (referralCode) => {
    const req = { body: {
      email: `invitee-${randomUUID()}@example.invalid`,
      password: 'Referral-Test-2026!',
      data: { signup_referral_code: referralCode },
    } };
    let status, result;
    await handler(req, { status(code) { status = code; return this; }, json(body) { result = body; } });
    assert.equal(status, 200, JSON.stringify(result));
    return result.user.id;
  };
  const invitee = await signup(code.toUpperCase());
  assert.equal((await referral(invitee)).referrer_id, referrer);
  assert.equal((await referral(invitee)).source, 'email');
  assert.equal(await referral(await signup(code)), undefined, 'referrer limit');
  assert.equal(await referral(await signup('unknown-code')), undefined);
  await setting('program_enabled', 'false');
  await setting('max_referrals_per_user', '100');
  assert.equal(await referral(await signup(code)), undefined, 'disabled program');
  await setting('program_enabled', 'true');

  await db.query("SELECT set_config('request.jwt.claim.role','service_role',true)");
  const addPayment = async (amount, provider = 'robokassa') => (await db.query(
    'INSERT INTO public.payments(user_id,amount,payment_system) VALUES($1,$2,$3) RETURNING id',
    [invitee, amount, provider],
  )).rows[0].id;
  const complete = async (id, amount) => (await db.query(
    'SELECT public.process_payment_completion($1,$2) AS result', [id, amount],
  )).rows[0].result;
  const startingBalance = await balance(referrer);
  assert.equal((await complete(await addPayment(99), 99)).success, true);
  assert.equal((await complete(await addPayment(500, 'yookassa'), 500)).success, true);
  assert.equal(await balance(referrer), startingBalance);
  const payment = await addPayment(259);
  assert.equal((await complete(payment, 259)).success, true);
  assert.equal(await balance(referrer), startingBalance + 25);
  assert.equal((await referral(invitee)).status, 'active');
  assert.equal((await complete(payment, 259)).already_processed, true);
  assert.equal((await complete(await addPayment(1000), 1000)).success, true);
  assert.equal(await balance(referrer), startingBalance + 25);
  await setting('program_enabled', 'false');
  const refund = (await db.query('SELECT public.process_payment_refund($1,$2) AS result', [payment, 259])).rows[0].result;
  assert.equal(refund.success, true);
  assert.equal(await balance(referrer), startingBalance);
  assert.equal((await referral(invitee)).status, 'pending');
  const ledger = await db.query(
    "SELECT amount FROM public.balance_transactions WHERE user_id=$1 AND type='referral_bonus' ORDER BY amount",
    [referrer],
  );
  assert.deepEqual(ledger.rows.map(row => Number(row.amount)), [-25, 25]);
  console.log('Email referral, limits, payment, replay, repeat payment and refund passed.');
} finally {
  await db.query('ROLLBACK');
  db.release();
  await pool.end();
}
