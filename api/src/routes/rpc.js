/**
 * RPC Routes — вызов PostgreSQL функций
 * POST /rest/v1/rpc/:function_name
 * Body: { param1: val1, param2: val2 }
 */
import { Router } from 'express';
import { pool } from '../db.js';
import { rpcAnonLimiter, votingIpLimiter, votingUserLimiter } from '../middleware/votingRateLimit.js';

const router = Router();

/** Общий rate limit для анонимов — на все RPC */
const anonThenVoting = (req, res, next) => {
  rpcAnonLimiter(req, res, (err) => {
    if (err) return next(err);
    votingRateLimit(req, res, next);
  });
};

/** Rate limit только для cast_weighted_vote */
function votingRateLimit(req, res, next) {
  if (req.params.fn !== 'cast_weighted_vote') return next();
  votingIpLimiter(req, res, (err) => {
    if (err) return next(err);
    votingUserLimiter(req, res, next);
  });
}

// Обработчик POST и GET для RPC
async function handleRpc(req, res) {
  // Получаем отдельное соединение для установки JWT claims
  const client = await pool.connect();
  try {
    const fnName = req.params.fn;
    // Валидация имени функции
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(fnName)) {
      return res.status(400).json({ error: 'Invalid function name' });
    }

    // ── Транзакция: set_config + вызов функции должны быть в одной TX ──
    // Без BEGIN/COMMIT set_config(is_local=true) теряется между autocommit-запросами
    await client.query('BEGIN');

    if (req.user && req.user.id && req.user.id !== 'service-role') {
      await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [req.user.id]);
      await client.query(`SELECT set_config('request.jwt.claim.role', $1, true)`, [req.user.role || 'authenticated']);
      if (req.user.email) {
        await client.query(`SELECT set_config('request.jwt.claim.email', $1, true)`, [req.user.email]);
      }
    }

    const params = (req.method === 'GET') ? req.query : (req.body || {});
    const KEY_REGEX = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
    const keys = Object.keys(params).filter(k =>
      !['select', 'order', 'limit', 'offset'].includes(k) && KEY_REGEX.test(k)
    );
    const rejectedKeys = Object.keys(params).filter(k =>
      !['select', 'order', 'limit', 'offset'].includes(k) && !KEY_REGEX.test(k)
    );
    if (rejectedKeys.length > 0) {
      return res.status(400).json({ error: 'Invalid parameter names', rejected: rejectedKeys });
    }

    let sql;
    let sqlParams;

    if (keys.length === 0) {
      sql = `SELECT * FROM public.${fnName}()`;
      sqlParams = [];
    } else {
      const namedParams = keys.map((k, i) => `"${k}" := $${i + 1}`);
      sql = `SELECT * FROM public.${fnName}(${namedParams.join(', ')})`;
      sqlParams = keys.map(k => {
        const v = params[k];
        if (Array.isArray(v)) {
          return `{${v.join(',')}}`;
        }
        return (v !== null && typeof v === 'object') ? JSON.stringify(v) : v;
      });
    }

    const result = await client.query(sql, sqlParams);

    await client.query('COMMIT');

    // Если функция возвращает одну строку с одной колонкой — возвращаем значение напрямую
    if (result.rows.length === 1 && result.fields.length === 1) {
      const val = result.rows[0][result.fields[0].name];
      return res.json(val);
    }

    res.json(result.rows);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    // Return null only for "function does not exist" (PostgREST compatibility)
    if (err.message.includes('function') && err.message.includes('does not exist')) {
      return res.json(null);
    }
    console.error('[RPC]', req.params.fn, err.message);
    res.status(400).json({ message: err.message, error: err.message, code: 'RPC_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
}

router.post('/:fn', anonThenVoting, handleRpc);
router.get('/:fn', anonThenVoting, handleRpc);

export default router;
