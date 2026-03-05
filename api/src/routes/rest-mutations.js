import { pool } from '../db.js';
import { setJwtClaims, resetJwtClaims, sanitizeTable, parseFilters, parseSelect } from './rest-utils.js';

const PROTECTED_COLUMNS = new Set([
  'role', 'is_super_admin', 'balance', 'likes_count', 'plays_count',
  'moderation_status', 'moderation_reviewed_by', 'moderation_reviewed_at',
  'voting_result', 'voting_likes_count', 'voting_dislikes_count',
  'chart_position', 'chart_score', 'weighted_likes_sum', 'weighted_dislikes_sum',
  'created_at', 'downloads_count', 'shares_count', 'xp', 'level', 'tier',
  'vote_weight', 'reputation_score', 'authority_score',
]);

const MAX_BATCH_SIZE = 100;

function isAdminUser(user) {
  if (user?.role === 'service_role') return true;
  const r = (user?.app_role || '').toLowerCase();
  return r === 'admin' || r === 'super_admin' || r === 'superadmin';
}

function filterProtectedCols(cols, user) {
  if (isAdminUser(user)) return cols;
  return cols.filter(c => !PROTECTED_COLUMNS.has(c));
}

export async function handlePost(req, res) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const table = sanitizeTable(req.params.table);
    const rows = Array.isArray(req.body) ? req.body : [req.body];
    if (rows.length === 0) { await client.query('ROLLBACK'); return res.status(400).json({ error: 'No data' }); }
    if (rows.length > MAX_BATCH_SIZE) { await client.query('ROLLBACK'); return res.status(400).json({ error: `Batch size exceeds limit of ${MAX_BATCH_SIZE}` }); }

    const results = [];
    for (const row of rows) {
      const cols = filterProtectedCols(Object.keys(row).filter(c => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c)), req.user);
      if (cols.length === 0) { await client.query('ROLLBACK'); return res.status(400).json({ error: 'No valid columns' }); }

      const vals = cols.map(c => row[c]);
      const placeholders = cols.map((_, i) => {
        const v = vals[i];
        if (v !== null && typeof v === 'object') return `$${i + 1}::jsonb`;
        return `$${i + 1}`;
      });
      const sqlParams = vals.map(v => (v !== null && typeof v === 'object') ? JSON.stringify(v) : v);

      const prefer = req.headers.prefer || '';
      let sql;
      const onConflict = req.query.on_conflict;
      if (prefer.includes('resolution=merge-duplicates') && onConflict) {
        const conflictCols = onConflict.split(',')
          .map(c => c.trim())
          .filter(c => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c))
          .map(c => `"${c}"`).join(', ');
        if (!conflictCols) { await client.query('ROLLBACK'); return res.status(400).json({ error: 'Invalid on_conflict columns' }); }
        const conflictNames = onConflict.split(',').map(x => x.trim());
        const updateCols = cols
          .filter(c => !conflictNames.includes(c))
          .map(c => `"${c}" = EXCLUDED."${c}"`);
        sql = `INSERT INTO ${table} (${cols.map(c => `"${c}"`).join(', ')}) VALUES (${placeholders.join(', ')})
               ON CONFLICT (${conflictCols}) DO UPDATE SET ${updateCols.join(', ')}
               RETURNING *`;
      } else {
        sql = `INSERT INTO ${table} (${cols.map(c => `"${c}"`).join(', ')}) VALUES (${placeholders.join(', ')}) RETURNING *`;
      }

      const result = await client.query(sql, sqlParams);
      results.push(...result.rows);
    }

    const selectStr = req.query.select;
    if (selectStr && selectStr !== '*' && results.length > 0) {
      try {
        const { columns: selectCols } = parseSelect(selectStr, table);
        if (selectCols !== '*') {
          const ids = results.map(r => r.id).filter(Boolean);
          if (ids.length > 0) {
            const phs = ids.map((_, i) => `$${i + 1}`).join(', ');
            const enrichSql = `SELECT ${selectCols} FROM ${table} WHERE "id" IN (${phs})`;
            const enrichResult = await client.query(enrichSql, ids);
            const enrichMap = new Map(enrichResult.rows.map(r => [r.id, r]));
            for (let i = 0; i < results.length; i++) {
              if (results[i].id && enrichMap.has(results[i].id)) {
                results[i] = enrichMap.get(results[i].id);
              }
            }
          }
        }
      } catch (enrichErr) {
        console.warn('[REST POST] Select enrichment failed:', enrichErr.message);
      }
    }

    await client.query('COMMIT');

    const prefer2 = req.headers.prefer || '';
    if (prefer2.includes('return=representation')) {
      const acceptHeader = req.headers.accept || '';
      if (acceptHeader.includes('vnd.pgrst.object+json')) {
        if (results.length === 0) {
          return res.status(406).json({
            message: 'JSON object requested, multiple (or no) rows returned',
            code: 'PGRST116',
            details: 'The result contains 0 rows',
            hint: null,
          });
        }
        return res.status(201).json(results[0]);
      }
      return res.status(201).json(rows.length === 1 ? results[0] : results);
    }
    res.status(201).json(results);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST POST]', err.message, '| table:', req.params.table, '| code:', err.code);
    const pgMsg = err.message || 'Operation failed';
    const pgCode = err.code || 'REST_ERROR';
    res.status(400).json({ message: pgMsg, error: pgMsg, code: pgCode, details: err.detail || null, hint: err.hint || null });
  } finally {
    await resetJwtClaims(client);
    client.release();
  }
}

export async function handlePatch(req, res) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const table = sanitizeTable(req.params.table);
    const updates = req.body;
    const cols = filterProtectedCols(Object.keys(updates).filter(c => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c)), req.user);
    if (cols.length === 0) { await client.query('ROLLBACK'); return res.status(400).json({ error: 'No valid columns' }); }

    const setClauses = [];
    const setParams = [];
    let idx = 1;

    for (const col of cols) {
      const val = updates[col];
      if (val !== null && typeof val === 'object') {
        setClauses.push(`"${col}" = $${idx++}::jsonb`);
        setParams.push(JSON.stringify(val));
      } else {
        setClauses.push(`"${col}" = $${idx++}`);
        setParams.push(val);
      }
    }

    const { where, params: filterParams } = parseFilters(req.query);
    const adjustedWhere = where.replace(/\$(\d+)/g, (_, n) => `$${parseInt(n) + idx - 1}`);

    const sql = `UPDATE ${table} SET ${setClauses.join(', ')} ${adjustedWhere} RETURNING *`;
    const result = await client.query(sql, [...setParams, ...filterParams]);

    await client.query('COMMIT');

    const prefer = req.headers.prefer || '';
    if (prefer.includes('return=representation')) {
      const acceptHeader = req.headers.accept || '';
      if (acceptHeader.includes('vnd.pgrst.object+json')) {
        if (result.rows.length === 0) {
          return res.status(406).json({
            message: 'JSON object requested, multiple (or no) rows returned',
            code: 'PGRST116',
            details: 'The result contains 0 rows',
            hint: null,
          });
        }
        return res.json(result.rows[0]);
      }
      return res.json(result.rows);
    }
    res.status(204).end();
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST PATCH]', err.message, '| table:', req.params.table, '| code:', err.code);
    const pgMsg = err.message || 'Operation failed';
    const pgCode = err.code || 'REST_ERROR';
    res.status(400).json({ message: pgMsg, error: pgMsg, code: pgCode, details: err.detail || null, hint: err.hint || null });
  } finally {
    await resetJwtClaims(client);
    client.release();
  }
}

export async function handleDelete(req, res) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const table = sanitizeTable(req.params.table);
    const { where, params } = parseFilters(req.query);
    if (!where) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'Filters required for DELETE' });
    }
    const sql = `DELETE FROM ${table} ${where} RETURNING *`;
    const result = await client.query(sql, params);

    await client.query('COMMIT');

    const prefer = req.headers.prefer || '';
    if (prefer.includes('return=representation')) {
      const acceptHeader = req.headers.accept || '';
      if (acceptHeader.includes('vnd.pgrst.object+json')) {
        return res.json(result.rows[0] || null);
      }
      return res.json(result.rows);
    }
    res.status(204).end();
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST DELETE]', err.message, '| table:', req.params.table, '| code:', err.code);
    const pgMsg = err.message || 'Operation failed';
    const pgCode = err.code || 'REST_ERROR';
    res.status(400).json({ message: pgMsg, error: pgMsg, code: pgCode, details: err.detail || null, hint: err.hint || null });
  } finally {
    await resetJwtClaims(client);
    client.release();
  }
}
