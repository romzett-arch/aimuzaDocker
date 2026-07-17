/**
 * Rate limiters для RPC
 * - rpcAnonLimiter: общий лимит для анонимов на все RPC (60/мин/IP)
 * - votingIpLimiter: 20 голосов / час / IP (cast_weighted_vote)
 * - votingUserLimiter: 100 голосов / день / user (cast_weighted_vote)
 */
import rateLimit from 'express-rate-limit';

/** Общий лимит для анонимов — защита от мусорных вызовов RPC */
export const rpcAnonLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 минута
  max: 60,
  skip: (req) => !!req.user?.id,
  message: { error: 'Слишком много запросов. Войдите в аккаунт или попробуйте позже.', code: 'RPC_ANON_RATE_LIMIT' },
  standardHeaders: true,
  legacyHeaders: false,
});

export const votingIpLimiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 час
  max: 20,
  message: { error: 'Слишком много голосов. Попробуйте через час.', code: 'VOTING_RATE_LIMIT' },
  standardHeaders: true,
  legacyHeaders: false,
});

export const votingUserLimiter = rateLimit({
  windowMs: 24 * 60 * 60 * 1000, // 1 день
  max: 100,
  keyGenerator: (req) => (req.user?.id ? `user:${req.user.id}` : `ip:${req.ip}`),
  skip: (req) => !req.user?.id, // для анонимов — только IP limiter
  message: { error: 'Дневной лимит голосов исчерпан (100/день).', code: 'VOTING_DAILY_LIMIT' },
  standardHeaders: true,
  legacyHeaders: false,
});

