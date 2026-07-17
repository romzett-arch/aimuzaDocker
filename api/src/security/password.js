import crypto from 'crypto';

export const PASSWORD_POLICY_MESSAGE =
  'Пароль должен содержать минимум 8 символов, заглавную букву, цифру и спецсимвол';

export function validatePassword(password) {
  return typeof password === 'string'
    && password.length >= 8
    && /[A-ZА-ЯЁ]/.test(password)
    && /[0-9]/.test(password)
    && /[^A-Za-zА-Яа-яЁё0-9]/.test(password);
}

export function normalizeRecoveryToken(token) {
  if (typeof token !== 'string') return null;
  const normalized = token.trim().toLowerCase();
  return /^[a-f0-9]{64}$/.test(normalized) ? normalized : null;
}

export function hashRecoveryToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

export function recoveryCodeForToken(token) {
  return `RESET:${hashRecoveryToken(token)}`;
}
