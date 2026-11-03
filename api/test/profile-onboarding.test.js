import { test } from 'node:test';
import assert from 'node:assert/strict';
import { needsNickname, normalizeNickname } from '../src/security/profile-onboarding.js';

test('both new providers require an explicit nickname choice', () => {
  for (const provider of ['vkid', 'yandex']) {
    assert.equal(needsNickname({ provider, nickname_required: true }, 'anything'), true);
    assert.equal(needsNickname({ provider, nickname_required: true, nickname_selected_at: '2026-11-03' }, 'anything'), false);
  }
});
test('legacy generated names require choice, manually changed names and email accounts do not', () => {
  for (const [provider, prefix] of [['vkid', 'vk_'], ['yandex', 'ya_']]) {
    const username = prefix + 'X'.repeat(24);
    assert.equal(needsNickname({ provider, username }, username), true);
    assert.equal(needsNickname({ provider, username }, 'Музыкант'), false);
    assert.equal(needsNickname({ provider, username: 'ya_rock' }, 'ya_rock'), false);
    assert.equal(needsNickname({ provider: 'email', username }, username), false);
  }
});
test('nicknames normalize whitespace and accept Russian/Latin stage names', () => {
  assert.equal(normalizeNickname('  Мой   артист-2  '), 'Мой артист-2');
  assert.equal(normalizeNickname('DJ_Name.2'), 'DJ_Name.2');
  for (const value of [null, {}, 'ab', 'a'.repeat(31), '<script>', 'name\nline', 'ya_' + 'X'.repeat(24), 'vk_' + 'a'.repeat(32)]) {
    assert.equal(normalizeNickname(value), null);
  }
});
