// Run explicitly against the local migrated database; every fixture rolls back.
import assert from 'node:assert/strict';
import { pool } from '../src/db.js';
import { resolveYandexUser } from '../src/routes/auth-yandex.js';
import { secret } from '../src/security/yandex.js';

const client = await pool.connect();
let checks = 0;
try {
  await client.query('BEGIN');
  const subject = String(Date.now());
  const profile = { subject, email: `yandex-test-${secret().slice(0, 10)}@example.com`, name: 'VK test' };
  const flow = { profile, consent: true };
  const created = await resolveYandexUser(client, flow);
  assert.ok(created.email_confirmed_at); checks++;
  const before = (await client.query('SELECT balance FROM public.profiles WHERE user_id=$1', [created.id])).rows[0].balance;
  const again = await resolveYandexUser(client, { ...flow, consent: false });
  assert.equal(again.id, created.id); checks++;
  assert.equal((await client.query('SELECT balance FROM public.profiles WHERE user_id=$1', [created.id])).rows[0].balance, before); checks++;
  await assert.rejects(resolveYandexUser(client, { consent: true, profile: { ...profile, subject: subject + '1' } }), /YANDEX_LINK_REQUIRED/); checks++;
  await assert.rejects(resolveYandexUser(client, { consent: false, profile: { ...profile, subject: subject + '2', email: 'fresh-' + profile.email } }), /YANDEX_CONSENT_REQUIRED/); checks++;
  await assert.rejects(resolveYandexUser(client, { consent: true, profile: { ...profile, subject: subject + '3', email: '' } }), /YANDEX_EMAIL_REQUIRED/); checks++;
  await assert.rejects(resolveYandexUser(client, { profile, link_user_id: created.id, link_version: 1 }), /YANDEX_SESSION_EXPIRED/); checks++;
  const linked = await resolveYandexUser(client, { profile, link_user_id: created.id, link_version: 0 });
  assert.equal(linked.id, created.id); checks++;
  await client.query('DELETE FROM auth.yandex_identities WHERE user_id=$1', [created.id]);
  const same = await resolveYandexUser(client, { profile: { ...profile, subject: subject + '4' }, link_user_id: created.id, link_version: 0 });
  assert.equal(same.id, created.id); checks++;
  assert.equal((await client.query('SELECT balance FROM public.profiles WHERE user_id=$1', [created.id])).rows[0].balance, before); checks++;
  await client.query("UPDATE auth.users SET raw_user_meta_data=raw_user_meta_data || '{\"deleted_at\":\"test\"}'::jsonb WHERE id=$1", [created.id]);
  await assert.rejects(resolveYandexUser(client, { profile: { ...profile, subject: subject + '4' }, consent: true }), /YANDEX_ACCOUNT_UNAVAILABLE/); checks++;
  console.log(`Yandex ID database checks passed: ${checks}. All fixtures rolled back.`);
} finally {
  await client.query('ROLLBACK');
  client.release();
  await pool.end();
}
