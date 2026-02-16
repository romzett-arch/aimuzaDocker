/**
 * AI Planet Sound — API Server
 * Замена Supabase PostgREST + GoTrue Auth
 * 
 * Эндпоинты:
 *   POST   /auth/signup          — регистрация
 *   POST   /auth/login           — вход
 *   POST   /auth/logout          — выход
 *   GET    /auth/session         — текущая сессия
 *   POST   /auth/update-user     — обновление пароля/email
 *   GET    /rest/v1/:table       — SELECT (с фильтрами, сортировкой, пагинацией)
 *   POST   /rest/v1/:table       — INSERT
 *   PATCH  /rest/v1/:table       — UPDATE (с фильтрами)
 *   DELETE /rest/v1/:table       — DELETE (с фильтрами)
 *   POST   /rest/v1/rpc/:fn      — вызов RPC-функции
 *   POST   /storage/v1/object/:bucket/:path  — загрузка файла
 *   GET    /storage/v1/object/public/:bucket/:path — скачать публичный файл
 *   POST   /functions/v1/:name   — вызов Edge Function (проксирование в Deno)
 */
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import rateLimit from 'express-rate-limit';
import dotenv from 'dotenv';

import { pool, testConnection } from './db.js';
import authRouter from './routes/auth.js';
import restRouter from './routes/rest.js';
import rpcRouter from './routes/rpc.js';
import storageRouter from './routes/storage.js';
import emailRouter from './routes/email.js';
import functionsRouter from './routes/functions.js';
import { authMiddleware } from './middleware/auth.js';

dotenv.config();

const app = express();
const PORT = parseInt(process.env.API_PORT || '3000');

// Middleware
app.use(helmet({ contentSecurityPolicy: false }));
// A9: Explicit CORS origins instead of wildcard with credentials
const ALLOWED_ORIGINS = (process.env.CORS_ORIGIN || 'http://localhost').split(',').map(s => s.trim());
app.use(cors({
  origin: ALLOWED_ORIGINS,
  credentials: true,
}));
app.use(morgan('short'));

// Raw body parser for storage upload routes (binary files)
app.use('/storage/v1/object', express.raw({
  type: ['image/*', 'audio/*', 'video/*', 'application/octet-stream', 'application/pdf', 'application/zip', 'text/html', 'text/html; charset=utf-8'],
  limit: '100mb',
}));

app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// A10: Rate limiting — защита от брутфорса и спама
app.use('/auth/v1/token', rateLimit({ windowMs: 15 * 60 * 1000, max: 30, message: { error: 'Too many login attempts, try again later' } }));
app.use('/auth/v1/signup', rateLimit({ windowMs: 60 * 60 * 1000, max: 10, message: { error: 'Too many signup attempts, try again later' } }));
app.use('/functions/v1/send-auth-email', rateLimit({ windowMs: 60 * 1000, max: 3, message: { error: 'Too many email requests, try again later' } }));
app.use('/functions/v1/verify-email-code', rateLimit({ windowMs: 15 * 60 * 1000, max: 10, message: { error: 'Too many verification attempts' } }));

// JWT auth middleware (устанавливает req.user если токен валидный)
app.use(authMiddleware);

// Healthcheck
app.get('/health', (req, res) => res.json({ status: 'ok', timestamp: new Date().toISOString() }));

// Routes (порядок важен: rpc до rest, email до functions proxy)
app.use('/auth/v1', authRouter);
app.use('/rest/v1/rpc', rpcRouter);
app.use('/rest/v1', restRouter);
app.use('/storage/v1', storageRouter);
app.use('/functions/v1', emailRouter);       // Email — обрабатывается в Node.js (не Deno)
app.use('/functions/v1', functionsRouter);    // Остальные функции — проксируются в Deno

// Error handler
app.use((err, req, res, next) => {
  console.error('[API Error]', err.message, err.stack?.split('\n')[1]);
  res.status(err.status || 500).json({
    error: err.message || 'Internal Server Error',
    code: err.code || 'INTERNAL_ERROR',
  });
});

// Start
async function start() {
  await testConnection();
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[API] aimuza-api listening on :${PORT}`);
  });
}

start().catch(err => {
  console.error('[API] Failed to start:', err);
  process.exit(1);
});
