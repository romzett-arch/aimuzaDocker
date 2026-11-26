import rateLimit from 'express-rate-limit';

export const rpcAnonLimiter = rateLimit({
  windowMs: 60_000,
  max: 60,
  skip: (req) => !!req.user?.id,
  message: { error: 'Слишком много запросов. Войдите в аккаунт или попробуйте позже.', code: 'RPC_ANON_RATE_LIMIT' },
  standardHeaders: true,
  legacyHeaders: false,
});
