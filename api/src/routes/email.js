/**
 * Email Routes — отправка auth-писем и верификация кодов
 * Работает напрямую в Node.js (без Deno), т.к. nodemailer — npm пакет
 * 
 * POST /functions/v1/send-auth-email   — отправить код / welcome / reset
 * POST /functions/v1/verify-email-code  — проверить 6-значный код
 */
import { Router } from 'express';
import nodemailer from 'nodemailer';
import crypto from 'crypto';
import { requireAuth } from '../middleware/auth.js';
import { pool } from '../db.js';

const router = Router();

const APP_NAME = 'AIMUZA';
const BASE_URL = process.env.BASE_URL || 'http://localhost';

const SMTP_HOST = process.env.SMTP_HOST;
const SMTP_PORT = parseInt(process.env.SMTP_PORT || '465');
const SMTP_USER = process.env.SMTP_USER;
const SMTP_PASS = process.env.SMTP_PASS;
const SMTP_FROM = process.env.SMTP_FROM || `"${APP_NAME}" <${SMTP_USER}>`;

// ─── Генерация 6-значного кода ─────────────────
function generateCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // без O/0/1/I
  let code = '';
  for (let i = 0; i < 6; i++) {
    // A6: Use cryptographically secure random instead of Math.random
    code += chars[crypto.randomInt(chars.length)];
  }
  return code;
}

// ─── Транспорт nodemailer ──────────────────────
function createTransport() {
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

// ─── HTML шаблоны ──────────────────────────────
function getEmailHtml(type, { code, link, email, username }) {
  const baseStyle = `font-family:'Segoe UI',Arial,sans-serif;max-width:600px;margin:0 auto;background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:16px;overflow:hidden;color:#e0e0e0;`;
  const codeStyle = `display:inline-block;padding:16px 32px;background:rgba(139,92,246,0.2);border:2px solid #8b5cf6;border-radius:12px;font-size:32px;font-weight:700;letter-spacing:8px;color:#a78bfa;font-family:monospace;`;
  const buttonStyle = `display:inline-block;padding:14px 32px;background:linear-gradient(135deg,#8b5cf6,#6366f1);color:#ffffff;text-decoration:none;border-radius:12px;font-weight:600;font-size:16px;`;
  const header = `<div style="padding:32px 24px 16px;text-align:center;"><h1 style="color:#a78bfa;font-size:24px;margin:0;">🎵 ${APP_NAME}</h1></div>`;
  const footer = `<div style="padding:16px 24px 24px;text-align:center;font-size:12px;color:#666;"><p>Это автоматическое письмо от ${APP_NAME}.</p><p>Если вы не совершали это действие, проигнорируйте его.</p></div>`;

  if (type === 'confirm') {
    return {
      subject: `${code} — код подтверждения ${APP_NAME}`,
      html: `<div style="${baseStyle}">${header}<div style="padding:16px 24px 32px;"><h2 style="color:#e0e0e0;text-align:center;">Подтвердите регистрацию ✉️</h2><p style="text-align:center;line-height:1.6;">Привет, ${username || 'музыкант'}! Введите код ниже на странице регистрации:</p><div style="text-align:center;margin:24px 0;"><span style="${codeStyle}">${code}</span></div><p style="text-align:center;font-size:13px;color:#999;">Код действителен 15 минут.</p></div>${footer}</div>`,
    };
  }

  if (type === 'welcome') {
    return {
      subject: `Добро пожаловать в ${APP_NAME}! 🎵`,
      html: `<div style="${baseStyle}">${header}<div style="padding:16px 24px 32px;"><h2 style="color:#e0e0e0;text-align:center;">Привет, ${username || 'музыкант'}! 👋</h2><p style="text-align:center;line-height:1.6;">Добро пожаловать на платформу AIMUZA — хаб AI музыкантов!</p><div style="text-align:center;margin:24px 0;"><a href="${BASE_URL}" style="${buttonStyle}">Начать создавать 🚀</a></div><p style="text-align:center;font-size:14px;color:#999;">Ваш аккаунт: <strong>${email}</strong></p></div>${footer}</div>`,
    };
  }

  // reset
  return {
    subject: `Сброс пароля — ${APP_NAME}`,
    html: `<div style="${baseStyle}">${header}<div style="padding:16px 24px 32px;"><h2 style="color:#e0e0e0;text-align:center;">Сброс пароля 🔑</h2><p style="text-align:center;line-height:1.6;">Вы запросили сброс пароля для аккаунта <strong>${email}</strong>.</p><div style="text-align:center;margin:24px 0;"><a href="${link}" style="${buttonStyle}">Сбросить пароль</a></div><p style="text-align:center;font-size:13px;color:#999;">Ссылка действительна 1 час.</p></div>${footer}</div>`,
  };
}

// ═══════════════════════════════════════════════
// POST /functions/v1/send-auth-email
// ═══════════════════════════════════════════════
router.post('/send-auth-email', async (req, res) => {
  try {
    const { email, type, username } = req.body;
    if (!email || !type) {
      return res.status(400).json({ error: 'email and type are required' });
    }

    let code, link;

    if (type === 'confirm') {
      code = generateCode();

      // Удаляем старые коды для этого email
      await pool.query('DELETE FROM public.email_verifications WHERE email = $1', [email.toLowerCase()]);

      // Вставляем новый код
      await pool.query(
        `INSERT INTO public.email_verifications (email, code, username, verified, expires_at)
         VALUES ($1, $2, $3, false, now() + interval '15 minutes')`,
        [email.toLowerCase(), code, username || null]
      );
    }

    if (type === 'reset') {
      // Проверяем что пользователь существует
      const userRes = await pool.query('SELECT id FROM auth.users WHERE email = $1', [email.toLowerCase()]);
      if (userRes.rows.length === 0) {
        // Не раскрываем существование аккаунта
        return res.json({ success: true });
      }

      const token = crypto.randomBytes(32).toString('hex');
      await pool.query(
        `INSERT INTO public.email_verifications (email, code, verified, expires_at)
         VALUES ($1, $2, false, now() + interval '1 hour')`,
        [email.toLowerCase(), `RESET:${token}`]
      );
      link = `${BASE_URL}/auth?mode=reset&token=${token}&type=recovery`;
    }

    const template = getEmailHtml(type, { code, link, email, username });
    const transporter = createTransport();

    if (transporter) {
      await transporter.sendMail({
        from: SMTP_FROM,
        to: email,
        subject: template.subject,
        html: template.html,
      });
      console.log(`[Email] Sent ${type} to ${email}`);
    } else {
      console.log(`[Email] SMTP not configured. Code for ${email}: ${code || 'N/A'}`);
    }

    res.json({ success: true });
  } catch (err) {
    console.error('[Email] send-auth-email error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════
// POST /functions/v1/send-admin-email
// Полная версия: action=send (рассылка), action=unsubscribe
// ═══════════════════════════════════════════════
router.post('/send-admin-email', requireAuth, async (req, res) => {
  try {
    // A5: Проверяем что вызывающий — admin или superadmin
    const role = req.user?.app_role || req.user?.role || '';
    if (!['superadmin', 'admin', 'service_role'].includes(role)) {
      return res.status(403).json({ error: 'Forbidden: admin role required' });
    }

    const { action } = req.body;

    // Простой формат (to, subject, html) — обратная совместимость
    if (!action && req.body.to) {
      const { to, subject, html, text } = req.body;
      const transporter = createTransport();
      if (transporter) {
        await transporter.sendMail({
          from: SMTP_FROM,
          to,
          subject: subject || `${APP_NAME} — уведомление`,
          html: html || text || '',
        });
        console.log(`[Email] Admin email sent to ${to}`);
      }
      return res.json({ success: true });
    }

    // ── action=send: массовая рассылка ──
    if (action === 'send') {
      const { recipients, subject, body_html, sender_type, template_id } = req.body;

      if (!recipients?.length || !subject || !body_html) {
        return res.status(400).json({ error: 'Missing fields: recipients, subject, body_html' });
      }

      const senderId = req.user?.id || null;
      let sent = 0, failed = 0;
      const errors = [];

      const wrapHtml = (bodyHtml, sType, unsubUrl) => {
        const label = sType === 'personal' ? 'Личное сообщение от администратора' : APP_NAME;
        return `<div style="font-family:'Segoe UI',Arial,sans-serif;max-width:600px;margin:0 auto;background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:16px;overflow:hidden;color:#e0e0e0;"><div style="padding:32px 24px 16px;text-align:center;"><h1 style="color:#a78bfa;font-size:24px;margin:0;">🎵 ${APP_NAME}</h1><p style="font-size:12px;color:#888;margin-top:4px;">${label}</p></div><div style="padding:16px 24px 32px;">${bodyHtml}</div><div style="padding:16px 24px 24px;text-align:center;font-size:12px;color:#666;border-top:1px solid rgba(255,255,255,0.05);"><p>Это письмо от ${APP_NAME}.</p>${unsubUrl ? `<p><a href="${unsubUrl}" style="color:#888;text-decoration:underline;">Отписаться от рассылки</a></p>` : ''}</div></div>`;
      };

      const transporter = createTransport();

      for (const r of recipients) {
        try {
          const unsubscribeUrl = `${BASE_URL}/unsubscribe?uid=${r.user_id}`;
          const html = wrapHtml(body_html, sender_type || 'project', unsubscribeUrl);

          if (transporter) {
            await transporter.sendMail({ from: SMTP_FROM, to: r.email, subject, html });
          }

          await pool.query(
            `INSERT INTO public.admin_emails (sender_id, sender_type, recipient_id, recipient_email, subject, body_html, template_id, status)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'sent')`,
            [senderId, sender_type || 'project', r.user_id || null, r.email, subject, body_html, template_id || null]
          );
          sent++;
        } catch (err) {
          failed++;
          errors.push(`${r.email}: ${err.message}`);
          await pool.query(
            `INSERT INTO public.admin_emails (sender_id, sender_type, recipient_id, recipient_email, subject, body_html, template_id, status, error_message)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'failed', $8)`,
            [senderId, sender_type || 'project', r.user_id || null, r.email, subject, body_html, template_id || null, err.message]
          ).catch(() => {});
        }
      }

      console.log(`[Email] Admin send: ${sent} sent, ${failed} failed`);
      return res.json({ success: true, sent, failed, errors });
    }

    // ── action=unsubscribe ──
    if (action === 'unsubscribe') {
      const { user_id } = req.body;
      if (!user_id) return res.status(400).json({ error: 'user_id required' });

      await pool.query(
        'UPDATE public.profiles SET email_unsubscribed = true WHERE user_id = $1',
        [user_id]
      );
      return res.json({ success: true });
    }

    res.status(400).json({ error: 'Unknown action' });
  } catch (err) {
    console.error('[Email] send-admin-email error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════
// POST /functions/v1/verify-email-code
// ═══════════════════════════════════════════════
router.post('/verify-email-code', async (req, res) => {
  try {
    const { email, code } = req.body;
    if (!email || !code) {
      return res.status(400).json({ error: 'email and code are required' });
    }

    // Ищем совпадающий неиспользованный код
    const result = await pool.query(
      `SELECT id, email FROM public.email_verifications
       WHERE email = $1 AND code = $2 AND verified = false AND expires_at > now()
       ORDER BY created_at DESC LIMIT 1`,
      [email.toLowerCase(), code.toUpperCase().trim()]
    );

    if (result.rows.length === 0) {
      return res.status(400).json({ error: 'Неверный или просроченный код' });
    }

    const verification = result.rows[0];

    // Помечаем как подтверждённый
    await pool.query('UPDATE public.email_verifications SET verified = true WHERE id = $1', [verification.id]);

    // Подтверждаем email в auth.users
    await pool.query(
      'UPDATE auth.users SET email_confirmed_at = COALESCE(email_confirmed_at, now()), updated_at = now() WHERE email = $1',
      [email.toLowerCase()]
    );

    // Удаляем все коды для этого email
    await pool.query('DELETE FROM public.email_verifications WHERE email = $1', [email.toLowerCase()]);

    // Отправляем welcome-письмо
    const username = (await pool.query(
      'SELECT username FROM public.profiles WHERE email = $1 OR user_id = (SELECT id FROM auth.users WHERE email = $1)',
      [email.toLowerCase()]
    )).rows[0]?.username;

    const template = getEmailHtml('welcome', { email, username });
    const transporter = createTransport();
    if (transporter) {
      transporter.sendMail({
        from: SMTP_FROM,
        to: email,
        subject: template.subject,
        html: template.html,
      }).catch(err => console.error('[Email] Welcome email error:', err.message));
    }

    console.log(`[Email] Email verified: ${email}`);
    res.json({ success: true });
  } catch (err) {
    console.error('[Email] verify-email-code error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
