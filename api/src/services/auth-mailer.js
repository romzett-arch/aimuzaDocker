import { randomInt } from 'node:crypto';
import nodemailer from 'nodemailer';
import { pool } from '../db.js';

const APP_NAME = 'AIMUZA';
const SMTP_HOST = process.env.SMTP_HOST;
const SMTP_PORT = parseInt(process.env.SMTP_PORT || '465');
const SMTP_USER = process.env.SMTP_USER;
const SMTP_PASS = process.env.SMTP_PASS;
const SMTP_FROM = process.env.SMTP_FROM || `"${APP_NAME}" <${SMTP_USER}>`;

// A6: криптостойкий генератор, алфавит без O/0/1/I.
function generateCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 6; i++) code += chars[randomInt(chars.length)];
  return code;
}

// Единый SMTP-транспорт для auth-писем; null, если SMTP не настроен.
export function authTransport() {
  if (!SMTP_HOST || !SMTP_USER || !SMTP_PASS) {
    console.warn('[Email] SMTP not configured, emails will not be sent');
    return null;
  }
  return nodemailer.createTransport({
    host: SMTP_HOST,
    port: SMTP_PORT,
    secure: SMTP_PORT === 465,
    auth: { user: SMTP_USER, pass: SMTP_PASS },
  });
}

function page(inner) {
  const baseStyle = `font-family:'Segoe UI',Arial,sans-serif;max-width:600px;margin:0 auto;background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:16px;overflow:hidden;color:#e0e0e0;`;
  const header = `<div style="padding:32px 24px 16px;text-align:center;"><h1 style="color:#a78bfa;font-size:24px;margin:0;">🎵 ${APP_NAME}</h1></div>`;
  const footer = `<div style="padding:16px 24px 24px;text-align:center;font-size:12px;color:#666;"><p>Это автоматическое письмо от ${APP_NAME}.</p><p>Если вы не совершали это действие, проигнорируйте его.</p></div>`;
  return `<div style="${baseStyle}">${header}<div style="padding:16px 24px 32px;">${inner}</div>${footer}</div>`;
}

const codeStyle = `display:inline-block;padding:16px 32px;background:rgba(139,92,246,0.2);border:2px solid #8b5cf6;border-radius:12px;font-size:32px;font-weight:700;letter-spacing:8px;color:#a78bfa;font-family:monospace;`;

// Создаёт 6-значный код в public.email_verifications и отправляет письмом.
// Старые коды этого адреса заменяются. instruction — куда ввести код.
export async function issueEmailCode(email, { username, instruction } = {}) {
  const code = generateCode();
  await pool.query('DELETE FROM public.email_verifications WHERE email = $1', [email]);
  await pool.query(
    `INSERT INTO public.email_verifications (email, code, username, verified, expires_at)
     VALUES ($1, $2, $3, false, now() + interval '15 minutes')`,
    [email, code, username || null]
  );
  const subject = `${code} — код подтверждения ${APP_NAME}`;
  const html = page(`<h2 style="color:#e0e0e0;text-align:center;">Подтвердите регистрацию ✉️</h2><p style="text-align:center;line-height:1.6;">Привет, ${username || 'музыкант'}! ${instruction || 'Введите код ниже на странице регистрации:'}</p><div style="text-align:center;margin:24px 0;"><span style="${codeStyle}">${code}</span></div><p style="text-align:center;font-size:13px;color:#999;">Код действителен 15 минут.</p>`);
  const mailer = authTransport();
  if (mailer) {
    await mailer.sendMail({ from: SMTP_FROM, to: email, subject, html });
    console.log(`[Email] Sent confirm code to ${email}`);
  } else {
    console.log(`[Email] SMTP not configured. Code for ${email}: ${code}`);
  }
}

export function welcomeEmailHtml(email, username) {
  const BASE_URL = process.env.BASE_URL || 'http://localhost';
  const buttonStyle = `display:inline-block;padding:14px 32px;background:linear-gradient(135deg,#8b5cf6,#6366f1);color:#ffffff;text-decoration:none;border-radius:12px;font-weight:600;font-size:16px;`;
  return page(`<h2 style="color:#e0e0e0;text-align:center;">Привет, ${username || 'музыкант'}! 👋</h2><p style="text-align:center;line-height:1.6;">Добро пожаловать на платформу ${APP_NAME} — хаб AI музыкантов!</p><div style="text-align:center;margin:24px 0;"><a href="${BASE_URL}" style="${buttonStyle}">Начать создавать 🚀</a></div><p style="text-align:center;font-size:14px;color:#999;">Ваш аккаунт: <strong>${email}</strong></p>`);
}

export async function sendWelcomeEmail(email, username) {
  const mailer = authTransport();
  if (!mailer) return;
  await mailer.sendMail({
    from: SMTP_FROM,
    to: email,
    subject: `Добро пожаловать в ${APP_NAME}! 🎵`,
    html: welcomeEmailHtml(email, username),
  }).catch(err => console.error('[Email] Welcome email error:', err.message));
}

// Находит действительный код, помечает использованным и удаляет остальные коды адреса.
// client — соединение с уже открытым транзакцией (по умолчанию общий пул).
export async function consumeEmailCode(email, code, client = pool) {
  const { rows: [row] } = await client.query(
    `SELECT id FROM public.email_verifications
     WHERE email = $1 AND code = $2 AND verified = false AND expires_at > now()
     ORDER BY created_at DESC LIMIT 1`,
    [email, String(code).toUpperCase().trim()]
  );
  if (!row) return false;
  await client.query('UPDATE public.email_verifications SET verified = true WHERE id = $1', [row.id]);
  await client.query('DELETE FROM public.email_verifications WHERE email = $1', [email]);
  return true;
}
