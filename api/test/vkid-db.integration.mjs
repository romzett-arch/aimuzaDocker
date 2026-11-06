// Run explicitly against the local migrated database; every fixture rolls back.
import assert from 'node:assert/strict';
import { pool } from '../src/db.js';
import { resolveVkUser } from '../src/routes/auth-vkid.js';
import { secret } from '../src/security/vkid.js';

const client = await pool.connect();
let checks = 0;
try {
  await client.query('BEGIN');
  const subject = String(Date.now());
  const profile = { subject, email: `vkid-test-${secret().slice(0, 10)}@example.com`, name: 'VK test' };
  const flow = { profile, consent: true };
  const created = await resolveVkUser(client, flow);
  assert.ok(created.email_confirmed_at); checks++;
  const before = (await client.query('SELECT balance FROM public.profiles WHERE user_id=$1', [created.id])).rows[0].balance;
  const again = await resolveVkUser(client, { ...flow, consent: false });
  assert.equal(again.id, created.id); checks++;
  assert.equal((await client.query('SELECT balance FROM public.profiles WHERE user_id=$1', [created.id])).rows[0].balance, before); checks++;
  await assert.rejects(resolveVkUser(client, { consent: true, profile: { ...profile, subject: subject + '1' } }), /VKID_LINK_REQUIRED/); checks++;
  await assert.rejects(resolveVkUser(client, { consent: false, profile: { ...profile, subject: subject + '2', email: 'fresh-' + profile.email } }), /VKID_CONSENT_REQUIRED/); checks++;
  await assert.rejects(resolveVkUser(client, { consent: true, profile: { ...profile, subject: subject + '3', email: '' } }), /VKID_EMAIL_REQUIRED/); checks++;
  await assert.rejects(resolveVkUser(client, { profile, link_user_id: created.id, link_version: 1 }), /VKID_SESSION_EXPIRED/); checks++;
  const linked = await resolveVkUser(client, { profile, link_user_id: created.id, link_version: 0 });
  assert.equal(linked.id, created.id); checks++;
  await client.query('DELETE FROM auth.vkid_identities WHERE user_id=$1', [created.id]);
  const same = await resolveVkUser(client, { profile: { ...profile, subject: subject + '4' }, link_user_id: created.id, link_version: 0 });
  assert.equal(same.id, created.id); checks++;
  assert.equal((await client.query('SELECT balance FROM public.profiles WHERE user_id=$1', [created.id])).rows[0].balance, before); checks++;
  await client.query("UPDATE auth.users SET raw_user_meta_data=raw_user_meta_data || '{\"deleted_at\":\"test\"}'::jsonb WHERE id=$1", [created.id]);
  await assert.rejects(resolveVkUser(client, { profile: { ...profile, subject: subject + '4' }, consent: true }), /VKID_ACCOUNT_UNAVAILABLE/); checks++;
  console.log(`VK ID database checks passed: ${checks}. All fixtures rolled back.`);
} finally {
  await client.query('ROLLBACK');
  client.release();
  await pool.end();
}
