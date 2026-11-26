/**
 * Email Routes — отправка auth-писем и верификация кодов
 * Общая работа с письмами и кодами — в services/auth-mailer.js
 *
 * POST /functions/v1/send-auth-email   — отправить код / welcome / reset
 * POST /functions/v1/send-admin-email  — админ-рассылка и отписка
 * POST /functions/v1/verify-email-code — проверить 6-значный код
 */
import { Router } from 'express';
import crypto from 'crypto';
import { pool } from '../db.js';
import { recoveryCodeForToken } from '../security/password.js';
import { authTransport, issueEmailCode, sendWelcomeEmail, welcomeEmailHtml } from '../services/auth-mailer.js';
import { verifySignupEmail } from '../services/verify-signup-email.js';

const router = Router();

const APP_NAME = 'AIMUZA';
const BASE_URL = process.env.BASE_URL || 'http://localhost';
const SMTP_FROM = process.env.SMTP_FROM || `"${APP_NAME}" <${process.env.SMTP_USER}>`;
const UNSUBSCRIBE_SECRET = process.env.SERVICE_ROLE_KEY || process.env.JWT_SECRET;

function getUnsubscribeToken(userId) {
  return crypto.createHmac('sha256', UNSUBSCRIBE_SECRET).update(userId).digest('base64url');
}

function isValidUnsubscribeToken(userId, token) {
  if (!userId || !token || !UNSUBSCRIBE_SECRET) return false;
  const expected = Buffer.from(getUnsubscribeToken(userId));
  const received = Buffer.from(String(token));
  return expected.length === received.length && crypto.timingSafeEqual(expected, received);
}

// ─── HTML шаблон сброса пароля (код и welcome живут в auth-mailer) ──────────
function getResetHtml(link, email) {
  const baseStyle = `font-family:'Segoe UI',Arial,sans-serif;max-width:600px;margin:0 auto;background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:16px;overflow:hidden;color:#e0e0e0;`;
  const buttonStyle = `display:inline-block;padding:14px 32px;background:linear-gradient(135deg,#8b5cf6,#6366f1);color:#ffffff;text-decoration:none;border-radius:12px;font-weight:600;font-size:16px;`;
  const header = `<div style="padding:32px 24px 16px;text-align:center;"><h1 style="color:#a78bfa;font-size:24px;margin:0;">🎵 ${APP_NAME}</h1></div>`;
  const footer = `<div style="padding:16px 24px 24px;text-align:center;font-size:12px;color:#666;"><p>Это автоматическое письмо от ${APP_NAME}.</p><p>Если вы не совершали это действие, проигнорируйте его.</p></div>`;
  return `<div style="${baseStyle}">${header}<div style="padding:16px 24px 32px;"><h2 style="color:#e0e0e0;text-align:center;">Сброс пароля 🔑</h2><p style="text-align:center;line-height:1.6;">Вы запросили сброс пароля для аккаунта <strong>${email}</strong>.</p><div style="text-align:center;margin:24px 0;"><a href="${link}" style="${buttonStyle}">Сбросить пароль</a></div><p style="text-align:center;font-size:13px;color:#999;">Ссылка действительна 1 час.</p></div>${footer}</div>`;
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

    if (type === 'confirm') {
      await issueEmailCode(email.toLowerCase(), { username });
      return res.json({ success: true });
    }

    if (type === 'welcome') {
      const transporter = authTransport();
      if (transporter) {
        await transporter.sendMail({
          from: SMTP_FROM,
          to: email,
          subject: `Добро пожаловать в ${APP_NAME}! 🎵`,
          html: welcomeEmailHtml(email, username),
        });
        console.log(`[Email] Sent welcome to ${email}`);
      }
      return res.json({ success: true });
    }

    // reset
    const userRes = await pool.query('SELECT id FROM auth.users WHERE email = $1', [email.toLowerCase()]);
    if (userRes.rows.length === 0) {
      // Не раскрываем существование аккаунта
      return res.json({ success: true });
    }

    const token = crypto.randomBytes(32).toString('hex');
    await pool.query(
      `DELETE FROM public.email_verifications
       WHERE email = $1 AND code LIKE 'RESET:%'`,
      [email.toLowerCase()]
    );
    await pool.query(
      `INSERT INTO public.email_verifications (email, code, verified, expires_at)
       VALUES ($1, $2, false, now() + interval '1 hour')`,
      [email.toLowerCase(), recoveryCodeForToken(token)]
    );
    const link = `${BASE_URL}/auth?mode=reset&token=${token}&type=recovery`;

    const transporter = authTransport();
    if (transporter) {
      await transporter.sendMail({
        from: SMTP_FROM,
        to: email,
        subject: `Сброс пароля — ${APP_NAME}`,
        html: getResetHtml(link, email),
      });
      console.log(`[Email] Sent reset to ${email}`);
    } else {
      console.log(`[Email] SMTP not configured. Reset link for ${email}: ${link}`);
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
router.post('/send-admin-email', async (req, res) => {
  try {
    const { action } = req.body;

    if (action === 'unsubscribe') {
      const { user_id, token } = req.body;
      if (!isValidUnsubscribeToken(user_id, token)) {
        return res.status(403).json({ error: 'Invalid unsubscribe link' });
      }
      await pool.query('UPDATE public.profiles SET email_unsubscribed = true WHERE user_id = $1', [user_id]);
      return res.json({ success: true });
    }

    if (!req.user?.id) {
      return res.status(401).json({ error: 'Unauthorized', code: 'AUTH_REQUIRED' });
    }

    if (req.user.role !== 'service_role') {
      const adminCheck = await pool.query(
        `SELECT EXISTS (
           SELECT 1 FROM public.user_roles
           WHERE user_id = $1 AND role::text IN ('admin', 'super_admin')
         ) AS allowed`,
        [req.user.id]
      );
      if (!adminCheck.rows[0]?.allowed) {
        return res.status(403).json({ error: 'Forbidden: admin role required' });
      }
    }

    // Простой формат (to, subject, html) — обратная совместимость
    if (!action && req.body.to) {
      const { to, subject, html, text } = req.body;
      const transporter = authTransport();
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
      let sent = 0, failed = 0, skipped = 0;
      const errors = [];

      const recipientIds = recipients.map((recipient) => recipient.user_id).filter(Boolean);
      const unsubscribedResult = recipientIds.length
        ? await pool.query(
            'SELECT user_id FROM public.profiles WHERE user_id = ANY($1::uuid[]) AND email_unsubscribed IS TRUE',
            [recipientIds]
          )
        : { rows: [] };
      const unsubscribedIds = new Set(unsubscribedResult.rows.map((row) => row.user_id));

      const wrapHtml = (bodyHtml, sType, unsubUrl) => {
        const label = sType === 'personal' ? 'Личное сообщение от администратора' : APP_NAME;
        return `<div style="font-family:'Segoe UI',Arial,sans-serif;max-width:600px;margin:0 auto;background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:16px;overflow:hidden;color:#e0e0e0;"><div style="padding:32px 24px 16px;text-align:center;"><h1 style="color:#a78bfa;font-size:24px;margin:0;">🎵 ${APP_NAME}</h1><p style="font-size:12px;color:#888;margin-top:4px;">${label}</p></div><div style="padding:16px 24px 32px;">${bodyHtml}</div><div style="padding:16px 24px 24px;text-align:center;font-size:12px;color:#666;border-top:1px solid rgba(255,255,255,0.05);"><p>Это письмо от ${APP_NAME}.</p>${unsubUrl ? `<p><a href="${unsubUrl}" style="color:#888;text-decoration:underline;">Отписаться от рассылки</a></p>` : ''}</div></div>`;
      };

      const transporter = authTransport();

      for (const r of recipients) {
        if (r.user_id && unsubscribedIds.has(r.user_id)) {
          skipped++;
          continue;
        }
        try {
          const unsubscribeToken = getUnsubscribeToken(r.user_id);
          const unsubscribeUrl = `${BASE_URL}/unsubscribe?uid=${encodeURIComponent(r.user_id)}&token=${encodeURIComponent(unsubscribeToken)}`;
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

      console.log(`[Email] Admin send: ${sent} sent, ${failed} failed, ${skipped} skipped`);
      return res.json({ success: true, sent, failed, skipped, errors });
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
    const normalized = email.toLowerCase();

    const result = await verifySignupEmail(normalized, code);
    if (!result) {
      return res.status(400).json({ error: 'Неверный или просроченный код' });
    }

    // Отправляем welcome-письмо
    const username = (await pool.query(
      'SELECT username FROM public.profiles WHERE email = $1 OR user_id = (SELECT id FROM auth.users WHERE email = $1)',
      [normalized]
    )).rows[0]?.username;

    await sendWelcomeEmail(email, username);

    console.log(`[Email] Email verified: ${normalized}`);
    res.json({ success: true, signupPromoStatus: result.promoStatus });
  } catch (err) {
    console.error('[Email] verify-email-code error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
