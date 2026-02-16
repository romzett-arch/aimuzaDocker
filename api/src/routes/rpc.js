/**
 * RPC Routes — вызов PostgreSQL функций
 * POST /rest/v1/rpc/:function_name
 * Body: { param1: val1, param2: val2 }
 */
import { Router } from 'express';
import { pool } from '../db.js';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function sqlCastForValue(v) {
  if (typeof v === 'string' && UUID_RE.test(v)) return '::uuid';
  if (typeof v === 'number' && Number.isInteger(v)) return '::integer';
  if (typeof v === 'boolean') return '::boolean';
  if (v !== null && typeof v === 'object') return '::jsonb';
  return '';
}

// Обработчик POST и GET для RPC
async function handleRpc(req, res) {
  const client = await pool.connect();
  try {
    const fnName = req.params.fn;
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(fnName)) {
      return res.status(400).json({ error: 'Invalid function name' });
    }

    await client.query('BEGIN');

    if (req.user && req.user.id && req.user.id !== 'service-role') {
      await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [req.user.id]);
      await client.query(`SELECT set_config('request.jwt.claim.role', $1, true)`, [req.user.role || 'authenticated']);
      if (req.user.email) {
        await client.query(`SELECT set_config('request.jwt.claim.email', $1, true)`, [req.user.email]);
      }
    }

    const params = (req.method === 'GET') ? req.query : (req.body || {});
    const keys = Object.keys(params).filter(k => !['select','order','limit','offset'].includes(k));

    let sql;
    let sqlParams;

    if (keys.length === 0) {
      sql = `SELECT * FROM public.${fnName}()`;
      sqlParams = [];
    } else {
      const namedParams = keys.map((k, i) => {
        const cast = sqlCastForValue(params[k]);
        return `"${k}" := $${i + 1}${cast}`;
      });
      sql = `SELECT * FROM public.${fnName}(${namedParams.join(', ')})`;
      sqlParams = keys.map(k => {
        const v = params[k];
        return (v !== null && typeof v === 'object') ? JSON.stringify(v) : v;
      });
    }

    const result = await client.query(sql, sqlParams);
    await client.query('COMMIT');

    if (result.rows.length === 1 && result.fields.length === 1) {
      const val = result.rows[0][result.fields[0].name];
      return res.json(val);
    }

    res.json(result.rows);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    if (err.message.includes('does not exist')) {
      console.warn('[RPC] Function not found:', req.params.fn, '| Body:', JSON.stringify(req.body), '| Error:', err.message);
      return res.json(null);
    }
    console.error('[RPC]', req.params.fn, '| Body:', JSON.stringify(req.body), '| Error:', err.message);
    res.status(400).json({ message: err.message, error: err.message, code: 'RPC_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
}

router.post('/:fn', handleRpc);
router.get('/:fn', handleRpc);

export default router;
