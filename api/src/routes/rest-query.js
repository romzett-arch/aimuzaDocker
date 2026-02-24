import { pool } from '../db.js';
import { setJwtClaims, resetJwtClaims, sanitizeTable, parseFilters, parseSelect, parseOrder } from './rest-utils.js';

export async function handleHead(req, res) {
  try {
    const table = sanitizeTable(req.params.table);
    const { where, params } = parseFilters(req.query);
    const countSql = `SELECT COUNT(*) FROM ${table} ${where}`;
    const cr = await pool.query(countSql, params);
    res.set('Content-Range', `0-0/${cr.rows[0].count}`);
    res.set('X-Total-Count', String(cr.rows[0].count));
    res.status(200).end();
  } catch (err) {
    console.error('[REST HEAD]', err.message);
    res.status(200).set('Content-Range', '0-0/0').set('X-Total-Count', '0').end();
  }
}

export async function handleGet(req, res) {
  const client = await pool.connect();
  try {
    await setJwtClaims(client, req.user);

    const tableName = req.params.table;
    const table = sanitizeTable(tableName);
    const { columns } = parseSelect(req.query.select, table);
    const { where, params } = parseFilters(req.query);
    const order = parseOrder(req.query.order);
    const limit = parseInt(req.query.limit) || null;
    const offset = parseInt(req.query.offset) || 0;

    let sql = `SELECT ${columns} FROM ${table} ${where} ${order}`;
    if (limit) sql += ` LIMIT ${limit}`;
    if (offset) sql += ` OFFSET ${offset}`;

    const prefer = req.headers.prefer || '';
    let countResult = null;
    if (prefer.includes('count=exact')) {
      const countSql = `SELECT COUNT(*) FROM ${table} ${where}`;
      const cr = await client.query(countSql, params);
      countResult = parseInt(cr.rows[0].count);
    }

    const result = await client.query(sql, params);

    if (countResult !== null) {
      res.set('Content-Range', `0-${result.rows.length}/${countResult}`);
      res.set('X-Total-Count', String(countResult));
    }

    const acceptHeader = req.headers.accept || '';
    if (acceptHeader.includes('vnd.pgrst.object+json')) {
      return res.json(result.rows[0] || null);
    }

    res.json(result.rows);
  } catch (err) {
    console.error('[REST GET]', err.message, '| SQL table:', req.params.table, '| select:', req.query.select);
    if (err.message.includes('does not exist') || err.message.includes('column')) {
      return res.json([]);
    }
    res.status(400).json({ message: err.message, error: err.message, code: 'REST_ERROR', details: null, hint: null });
  } finally {
    await resetJwtClaims(client);
    client.release();
  }
}
