/**
 * JWT Auth Middleware
 * Извлекает и проверяет токен из Authorization: Bearer <token>
 * Устанавливает req.user если токен валидный
 */
import jwt from 'jsonwebtoken';

// A7: JWT_SECRET обязателен — не стартуем с дефолтным значением
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET.length < 32) {
  console.error('FATAL: JWT_SECRET env variable must be set (minimum 32 characters)');
  process.exit(1);
}

export function authMiddleware(req, res, next) {
  req.user = null;

  const authHeader = req.headers.authorization || req.headers.apikey;
  if (!authHeader) return next();

  let token = authHeader;
  if (authHeader.startsWith('Bearer ')) {
    token = authHeader.slice(7);
  }

  // Проверяем service role key (для внутренних вызовов между сервисами)
  if (token === process.env.SERVICE_ROLE_KEY) {
    req.user = { id: 'service-role', role: 'service_role', email: null };
    return next();
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    req.user = {
      id: decoded.sub,
      email: decoded.email,
      role: decoded.role || 'authenticated',
      app_role: decoded.app_role || null,
      is_super_admin: decoded.is_super_admin || false,
    };
  } catch (err) {
    // Невалидный токен — продолжаем как anon
  }

  next();
}

export function requireAuth(req, res, next) {
  if (!req.user || req.user.role === 'anon') {
    return res.status(401).json({ error: 'Unauthorized', code: 'AUTH_REQUIRED' });
  }
  next();
}

export function requireServiceRole(req, res, next) {
  if (!req.user || req.user.role !== 'service_role') {
    return res.status(403).json({ error: 'Forbidden', code: 'SERVICE_ROLE_REQUIRED' });
  }
  next();
}

export function signToken(user) {
  return jwt.sign(
    {
      sub: user.id,
      email: user.email,
      role: 'authenticated',
      aud: 'authenticated',
      is_super_admin: user.is_super_admin || false,
      app_role: user.app_role || 'user',
    },
    JWT_SECRET,
    { expiresIn: '7d' }
  );
}
