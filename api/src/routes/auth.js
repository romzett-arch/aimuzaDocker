/**
 * Auth Routes — замена Supabase GoTrue
 * 
 * POST /auth/v1/signup       — регистрация (email + password)
 * POST /auth/v1/token?grant_type=password  — вход
 * POST /auth/v1/logout       — выход (серверная сторона не хранит сессии)
 * GET  /auth/v1/user         — текущий пользователь
 * PUT  /auth/v1/user         — обновление (пароль, email)
 */
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import crypto from 'crypto';
import { pool } from '../db.js';
import { signToken, requireAuth, requireServiceRole } from '../middleware/auth.js';

const router = Router();
const BASE_URL = process.env.BASE_URL || 'http://localhost';

// ─── Регистрация ────────────────────────────
router.post('/signup', async (req, res) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    // Проверяем что email не занят
    const existing = await pool.query('SELECT id FROM auth.users WHERE email = $1', [email.toLowerCase()]);
    if (existing.rows.length > 0) {
      return res.status(400).json({ error: 'User already registered', code: 'USER_EXISTS' });
    }

    const hashed = await bcrypt.hash(password, 10);
    // Supabase SDK отправляет username в req.body.data.username (не options.data)
    const usernameFromBody = req.body.data?.username || req.body.options?.data?.username || email.split('@')[0];
    const metadata = { username: usernameFromBody, ...(req.body.data || {}) };

    const result = await pool.query(
      `INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
       VALUES ($1, $2, NULL, $3::jsonb, now(), now())
       RETURNING id, email, created_at`,
      [email.toLowerCase(), hashed, JSON.stringify(metadata)]
    );

    const user = result.rows[0];

    // Создаём/обновляем профиль (тригер handle_new_user тоже создаёт, поэтому DO UPDATE)
    await pool.query(
      `INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
       VALUES ($1, $2, $2, $3, 100, now(), now())
       ON CONFLICT (user_id) DO UPDATE SET
         username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
         display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
         email = COALESCE(EXCLUDED.email, public.profiles.email)`,
      [user.id, usernameFromBody, email.toLowerCase()]
    );

    // НЕ автоподтверждаем email — пользователь получит OTP-код
    // Но выдаём токен, чтобы фронтенд мог показать страницу верификации
    const token = signToken(user);

    res.status(200).json({
      access_token: token,
      token_type: 'bearer',
      expires_in: 604800,
      user: {
        id: user.id,
        email: user.email,
        created_at: user.created_at,
        email_confirmed_at: null,
        app_metadata: { provider: 'email' },
        user_metadata: { username: usernameFromBody },
      },
    });
  } catch (err) {
    console.error('[Auth] Signup error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Вход (Supabase-совместимый формат) ─────
router.post('/token', async (req, res) => {
  try {
    const grantType = req.query.grant_type || req.body.grant_type;
    
    if (grantType === 'password') {
      const { email, password } = req.body;
      if (!email || !password) {
        return res.status(400).json({ error: 'Email and password required' });
      }

      const result = await pool.query(
        'SELECT id, email, encrypted_password, email_confirmed_at, created_at, is_super_admin FROM auth.users WHERE email = $1',
        [email.toLowerCase()]
      );

      if (result.rows.length === 0) {
        return res.status(400).json({ error: 'Invalid login credentials', code: 'INVALID_CREDENTIALS' });
      }

      const user = result.rows[0];
      const valid = await bcrypt.compare(password, user.encrypted_password);
      if (!valid) {
        return res.status(400).json({ error: 'Invalid login credentials', code: 'INVALID_CREDENTIALS' });
      }

      // Проверяем подтверждение email
      if (!user.email_confirmed_at) {
        return res.status(400).json({
          error: 'Email not confirmed',
          code: 'EMAIL_NOT_CONFIRMED',
          message: 'Подтвердите email перед входом. Проверьте почту.',
        });
      }

      // Подтягиваем роль из profiles
      const profileRes = await pool.query(
        'SELECT role, is_super_admin, display_name FROM public.profiles WHERE user_id = $1',
        [user.id]
      );
      const profile = profileRes.rows[0];
      user.app_role = profile?.role || 'user';
      user.is_super_admin = user.is_super_admin || profile?.is_super_admin || false;

      // Обновляем last_sign_in_at
      await pool.query('UPDATE auth.users SET last_sign_in_at = now() WHERE id = $1', [user.id]);

      const token = signToken(user);
      const expiresIn = 604800; // 7 days
      const expiresAt = Math.round(Date.now() / 1000) + expiresIn;

      return res.json({
        access_token: token,
        token_type: 'bearer',
        expires_in: expiresIn,
        expires_at: expiresAt,
        refresh_token: token,
        user: {
          id: user.id,
          aud: 'authenticated',
          role: 'authenticated',
          email: user.email,
          created_at: user.created_at,
          updated_at: user.created_at,
          email_confirmed_at: user.email_confirmed_at,
          app_metadata: { provider: 'email', role: user.app_role },
          user_metadata: { display_name: profile?.display_name },
          is_super_admin: user.is_super_admin,
        },
      });
    }

    // refresh_token — просто продлеваем
    if (grantType === 'refresh_token') {
      if (!req.user) {
        return res.status(401).json({ error: 'Invalid refresh token' });
      }
      const result = await pool.query('SELECT id, email, created_at FROM auth.users WHERE id = $1', [req.user.id]);
      if (result.rows.length === 0) {
        return res.status(401).json({ error: 'User not found' });
      }
      const user = result.rows[0];
      const token = signToken(user);
      const expiresIn = 604800;
      const expiresAt = Math.round(Date.now() / 1000) + expiresIn;
      return res.json({
        access_token: token,
        token_type: 'bearer',
        expires_in: expiresIn,
        expires_at: expiresAt,
        refresh_token: token,
        user: {
          id: user.id,
          email: user.email,
          created_at: user.created_at,
          app_metadata: { provider: 'email' },
          user_metadata: {},
        },
      });
    }

    res.status(400).json({ error: 'Unsupported grant_type' });
  } catch (err) {
    console.error('[Auth] Token error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Logout ─────────────────────────────────
router.post('/logout', (req, res) => {
  // Stateless JWT — ничего не храним на сервере
  res.status(204).end();
});

// ─── Текущий пользователь ───────────────────
router.get('/user', requireAuth, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, email, created_at, is_super_admin, raw_user_meta_data FROM auth.users WHERE id = $1',
      [req.user.id]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const user = result.rows[0];
    
    // Подтягиваем профиль
    const profileRes = await pool.query(
      'SELECT role, is_super_admin, display_name, username FROM public.profiles WHERE user_id = $1',
      [user.id]
    );
    const profile = profileRes.rows[0];
    
    res.json({
      id: user.id,
      email: user.email,
      created_at: user.created_at,
      is_super_admin: user.is_super_admin || false,
      app_metadata: { provider: 'email', role: profile?.role || 'user' },
      user_metadata: {
        ...(user.raw_user_meta_data || {}),
        display_name: profile?.display_name || profile?.username,
      },
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── Обновление пользователя ────────────────
router.put('/user', requireAuth, async (req, res) => {
  try {
    const { password, email, data: metaData } = req.body;
    const updates = [];
    const params = [];
    let idx = 1;

    if (password) {
      const hashed = await bcrypt.hash(password, 10);
      updates.push(`encrypted_password = $${idx++}`);
      params.push(hashed);
    }
    if (email) {
      updates.push(`email = $${idx++}`);
      params.push(email.toLowerCase());
    }
    if (metaData) {
      updates.push(`raw_user_meta_data = raw_user_meta_data || $${idx++}::jsonb`);
      params.push(JSON.stringify(metaData));
    }

    updates.push(`updated_at = now()`);
    params.push(req.user.id);

    const result = await pool.query(
      `UPDATE auth.users SET ${updates.join(', ')} WHERE id = $${idx} RETURNING id, email, created_at`,
      params
    );

    const user = result.rows[0];
    res.json({
      id: user.id,
      email: user.email,
      created_at: user.created_at,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════════════════════════════════
// ADMIN API — используется Deno-функциями через service_role key
// ═══════════════════════════════════════════════════════════════════

// ─── List users (GET /auth/v1/admin/users) ─────
router.get('/admin/users', requireServiceRole, async (req, res) => {
  try {
    const page = parseInt(req.query.page) || 1;
    const perPage = parseInt(req.query.per_page) || 50;
    const offset = (page - 1) * perPage;

    const result = await pool.query(
      `SELECT id, email, encrypted_password, email_confirmed_at, is_super_admin,
              raw_user_meta_data, created_at, updated_at, last_sign_in_at
       FROM auth.users
       ORDER BY created_at DESC
       LIMIT $1 OFFSET $2`,
      [perPage, offset]
    );

    const countResult = await pool.query('SELECT COUNT(*) FROM auth.users');
    const total = parseInt(countResult.rows[0].count);

    res.json({
      users: result.rows.map(u => ({
        id: u.id,
        email: u.email,
        email_confirmed_at: u.email_confirmed_at,
        is_super_admin: u.is_super_admin || false,
        user_metadata: u.raw_user_meta_data || {},
        created_at: u.created_at,
        updated_at: u.updated_at,
        last_sign_in_at: u.last_sign_in_at,
      })),
      total,
      page,
      per_page: perPage,
    });
  } catch (err) {
    console.error('[Admin] List users error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Get single user (GET /auth/v1/admin/users/:id) ─────
router.get('/admin/users/:id', requireServiceRole, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT u.id, u.email, u.email_confirmed_at, u.is_super_admin,
              u.raw_user_meta_data, u.created_at, u.updated_at, u.last_sign_in_at,
              p.role AS app_role, p.username, p.display_name, p.avatar_url, p.balance
       FROM auth.users u
       LEFT JOIN public.profiles p ON p.user_id = u.id
       WHERE u.id = $1`,
      [req.params.id]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const u = result.rows[0];
    res.json({
      id: u.id,
      email: u.email,
      email_confirmed_at: u.email_confirmed_at,
      is_super_admin: u.is_super_admin || false,
      user_metadata: u.raw_user_meta_data || {},
      app_role: u.app_role || 'user',
      username: u.username,
      display_name: u.display_name,
      avatar_url: u.avatar_url,
      balance: u.balance,
      created_at: u.created_at,
      updated_at: u.updated_at,
      last_sign_in_at: u.last_sign_in_at,
    });
  } catch (err) {
    console.error('[Admin] Get user error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Create user (POST /auth/v1/admin/users) ─────
router.post('/admin/users', requireServiceRole, async (req, res) => {
  try {
    const { email, password, email_confirm, user_metadata } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    // Проверяем что email не занят
    const existing = await pool.query('SELECT id FROM auth.users WHERE email = $1', [email.toLowerCase()]);
    if (existing.rows.length > 0) {
      return res.status(400).json({ error: 'User already registered', code: 'USER_EXISTS' });
    }

    const hashed = await bcrypt.hash(password, 10);
    const meta = user_metadata || {};
    const username = meta.username || email.split('@')[0];

    const result = await pool.query(
      `INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
       VALUES ($1, $2, $3, $4::jsonb, now(), now())
       RETURNING id, email, email_confirmed_at, created_at`,
      [email.toLowerCase(), hashed, email_confirm ? new Date().toISOString() : null, JSON.stringify(meta)]
    );

    const user = result.rows[0];

    // Создаём/обновляем профиль
    await pool.query(
      `INSERT INTO public.profiles (user_id, username, display_name, email, balance, created_at, updated_at)
       VALUES ($1, $2, $2, $3, 100, now(), now())
       ON CONFLICT (user_id) DO UPDATE SET
         username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
         display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), public.profiles.display_name),
         email = COALESCE(EXCLUDED.email, public.profiles.email)`,
      [user.id, username, email.toLowerCase()]
    );

    res.status(200).json({
      user: {
        id: user.id,
        email: user.email,
        email_confirmed_at: user.email_confirmed_at,
        created_at: user.created_at,
        user_metadata: meta,
      },
    });
  } catch (err) {
    console.error('[Admin] Create user error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Update user by ID (PUT /auth/v1/admin/users/:id) ─────
router.put('/admin/users/:id', requireServiceRole, async (req, res) => {
  try {
    const userId = req.params.id;
    const { email, password, email_confirm, user_metadata, ban_duration } = req.body;
    
    const updates = [];
    const params = [];
    let idx = 1;

    if (email) {
      updates.push(`email = $${idx++}`);
      params.push(email.toLowerCase());
    }
    if (password) {
      const hashed = await bcrypt.hash(password, 10);
      updates.push(`encrypted_password = $${idx++}`);
      params.push(hashed);
    }
    if (email_confirm === true) {
      updates.push(`email_confirmed_at = COALESCE(email_confirmed_at, now())`);
    }
    if (email_confirm === false) {
      updates.push(`email_confirmed_at = NULL`);
    }
    if (user_metadata) {
      updates.push(`raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || $${idx++}::jsonb`);
      params.push(JSON.stringify(user_metadata));
    }
    if (ban_duration) {
      updates.push(`banned_until = now() + $${idx}::interval`);
      params.push(ban_duration);
      idx++;
    }

    updates.push('updated_at = now()');
    params.push(userId);

    if (updates.length <= 1) {
      // Only updated_at — nothing to do
      const result = await pool.query(
        'SELECT id, email, email_confirmed_at, raw_user_meta_data, created_at FROM auth.users WHERE id = $1',
        [userId]
      );
      const u = result.rows[0];
      if (!u) return res.status(404).json({ error: 'User not found' });
      return res.json({ id: u.id, email: u.email, email_confirmed_at: u.email_confirmed_at });
    }

    const sql = `UPDATE auth.users SET ${updates.join(', ')} WHERE id = $${idx} RETURNING id, email, email_confirmed_at, raw_user_meta_data, created_at`;
    const result = await pool.query(sql, params);

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const u = result.rows[0];
    res.json({
      id: u.id,
      email: u.email,
      email_confirmed_at: u.email_confirmed_at,
      user_metadata: u.raw_user_meta_data || {},
      created_at: u.created_at,
    });
  } catch (err) {
    console.error('[Admin] Update user error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Delete user (DELETE /auth/v1/admin/users/:id) ─────
router.delete('/admin/users/:id', requireServiceRole, async (req, res) => {
  try {
    const userId = req.params.id;

    // Защита суперадмина
    const check = await pool.query(
      'SELECT is_super_admin FROM auth.users WHERE id = $1',
      [userId]
    );
    if (check.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    if (check.rows[0].is_super_admin) {
      return res.status(403).json({ error: 'Cannot delete super admin' });
    }

    // Удаляем профиль и связанные данные (CASCADE в FK)
    await pool.query('DELETE FROM public.profiles WHERE user_id = $1', [userId]);
    await pool.query('DELETE FROM auth.users WHERE id = $1', [userId]);

    res.json({ id: userId });
  } catch (err) {
    console.error('[Admin] Delete user error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Generate link (POST /auth/v1/admin/generate_link) ─────
// Используется для сброса пароля (recovery link)
router.post('/admin/generate_link', requireServiceRole, async (req, res) => {
  try {
    const { type, email, options } = req.body;
    const redirectTo = options?.redirectTo || `${BASE_URL}/auth?mode=reset`;

    if (!email) {
      return res.status(400).json({ error: 'Email required' });
    }

    // Проверяем что пользователь существует
    const userResult = await pool.query(
      'SELECT id, email FROM auth.users WHERE email = $1',
      [email.toLowerCase()]
    );
    if (userResult.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const user = userResult.rows[0];

    if (type === 'recovery') {
      // Генерируем токен для сброса пароля
      const token = crypto.randomBytes(32).toString('hex');
      
      // Сохраняем токен в таблицу (используем email_verifications для простоты)
      await pool.query(
        `INSERT INTO public.email_verifications (email, code, verified, expires_at)
         VALUES ($1, $2, false, now() + interval '1 hour')`,
        [email.toLowerCase(), `RESET:${token}`]
      );

      const actionLink = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}&type=recovery`;

      res.json({
        data: {
          properties: {
            action_link: actionLink,
            hashed_token: token,
          },
        },
      });
    } else if (type === 'signup' || type === 'magiclink') {
      const token = crypto.randomBytes(32).toString('hex');
      const actionLink = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}&type=${type}`;
      
      res.json({
        data: {
          properties: {
            action_link: actionLink,
          },
        },
      });
    } else {
      res.status(400).json({ error: `Unsupported link type: ${type}` });
    }
  } catch (err) {
    console.error('[Admin] Generate link error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

export default router;
