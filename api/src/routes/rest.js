/**
 * REST Routes — замена PostgREST
 * Полная поддержка Supabase-совместимого синтаксиса:
 * 
 * GET    /rest/v1/:table?select=col1,col2&col.eq=val&order=col.asc&limit=10
 * POST   /rest/v1/:table
 * PATCH  /rest/v1/:table?col.eq=val
 * DELETE /rest/v1/:table?col.eq=val
 * HEAD   /rest/v1/:table  — только count
 * 
 * Фильтры: eq, neq, gt, gte, lt, lte, like, ilike, in, is, not, or
 * Headers: Prefer: return=representation, count=exact
 */
import { Router } from 'express';
import { pool } from '../db.js';
import { URL } from 'url';

const router = Router();

/**
 * Устанавливает JWT claims в PostgreSQL для auth.uid() / auth.role()
 * Критически важно для RLS-политик и триггеров.
 * ВАЖНО: Вызывать ВНУТРИ явной транзакции (BEGIN), т.к. set_config
 * с is_local=true действует только до конца текущей транзакции.
 * Без BEGIN каждый query — отдельная авто-транзакция, и claims теряются.
 */
async function setJwtClaims(client, user) {
  if (user && user.id && user.id !== 'service-role') {
    await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [user.id]);
    await client.query(`SELECT set_config('request.jwt.claim.role', $1, true)`, [user.role || 'authenticated']);
    if (user.email) {
      await client.query(`SELECT set_config('request.jwt.claim.email', $1, true)`, [user.email]);
    }
  }
}

function sanitizeTable(name) {
  // Разрешаем буквы, цифры, _, - (для таблиц типа message-attachments)
  if (!/^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(name)) throw new Error('Invalid table name');
  // Автоматически заменяем дефис на подчёркивание (PostgreSQL конвенция)
  const pgName = name.replace(/-/g, '_');
  return `public."${pgName}"`;
}

function sanitizeCol(col) {
  if (!/^[a-zA-Z_][a-zA-Z0-9_.]*$/.test(col)) return null;
  return `"${col}"`;
}

/**
 * Парсинг одного фильтра: operator.value
 */
function parseSingleFilter(col, value, params, paramIdx) {
  const filters = [];
  const sc = sanitizeCol(col);
  if (!sc) return { filters, params, paramIdx };

  // not.eq.val | not.is.null | not.in.(a,b)
  if (value.startsWith('not.')) {
    const inner = value.slice(4);
    if (inner.startsWith('is.null')) {
      filters.push(`${sc} IS NOT NULL`);
    } else if (inner.startsWith('is.true')) {
      filters.push(`${sc} IS NOT TRUE`);
    } else if (inner.startsWith('is.false')) {
      filters.push(`${sc} IS NOT FALSE`);
    } else if (inner.startsWith('eq.')) {
      filters.push(`${sc} != $${paramIdx}`);
      params.push(inner.slice(3));
      paramIdx++;
    } else if (inner.startsWith('neq.')) {
      filters.push(`${sc} = $${paramIdx}`);
      params.push(inner.slice(4));
      paramIdx++;
    } else if (inner.startsWith('in.')) {
      const vals = inner.slice(3).replace(/^\(|\)$/g, '').split(',');
      const phs = vals.map(() => `$${paramIdx++}`);
      filters.push(`${sc} NOT IN (${phs.join(', ')})`);
      params.push(...vals);
    }
    return { filters, params, paramIdx };
  }

  const match = value.match(/^(eq|neq|gt|gte|lt|lte|like|ilike|is|in|cs|cd|ov|fts|plfts|phfts|wfts)\.(.*)$/s);
  if (!match) return { filters, params, paramIdx };

  const [, op, val] = match;

  switch (op) {
    case 'eq':
      filters.push(`${sc} = $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'neq':
      filters.push(`${sc} != $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'gt':
      filters.push(`${sc} > $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'gte':
      filters.push(`${sc} >= $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'lt':
      filters.push(`${sc} < $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'lte':
      filters.push(`${sc} <= $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'like':
      filters.push(`${sc} LIKE $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'ilike':
      filters.push(`${sc} ILIKE $${paramIdx}`); params.push(val); paramIdx++; break;
    case 'is':
      if (val === 'null') filters.push(`${sc} IS NULL`);
      else if (val === 'true') filters.push(`${sc} IS TRUE`);
      else if (val === 'false') filters.push(`${sc} IS FALSE`);
      break;
    case 'in': {
      const raw = val.replace(/^\(|\)$/g, '').trim();
      if (!raw) {
        filters.push('FALSE'); // пустой IN — in.()
      } else {
        const vals = raw.split(',').map(v => v.trim()).filter(v => v !== '');
        if (vals.length === 0) {
          filters.push('FALSE');
        } else {
          const phs = vals.map(() => `$${paramIdx++}`);
          filters.push(`${sc} IN (${phs.join(', ')})`);
          params.push(...vals);
        }
      }
      break;
    }
    case 'cs': // contains (array)
      filters.push(`${sc} @> $${paramIdx}::jsonb`); params.push(val); paramIdx++; break;
    case 'cd': // contained by
      filters.push(`${sc} <@ $${paramIdx}::jsonb`); params.push(val); paramIdx++; break;
    case 'fts': case 'plfts': case 'phfts': case 'wfts':
      filters.push(`${sc} @@ to_tsquery($${paramIdx})`); params.push(val); paramIdx++; break;
  }

  return { filters, params, paramIdx };
}

/**
 * Парсинг or=(cond1,cond2,...) — PostgREST or-фильтр
 */
function parseOrFilter(value, params, paramIdx) {
  // value = (col1.op.val1,col2.op.val2)
  const inner = value.replace(/^\(|\)$/g, '');
  const conditions = [];
  
  // Разбиваем по запятым, но учитываем вложенные скобки
  let depth = 0;
  let current = '';
  for (const ch of inner) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) {
      conditions.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim()) conditions.push(current.trim());

  const orParts = [];
  for (const cond of conditions) {
    // col.op.val — разбиваем на col и op.val
    const dotIdx = cond.indexOf('.');
    if (dotIdx === -1) continue;
    const col = cond.substring(0, dotIdx);
    const opVal = cond.substring(dotIdx + 1);
    
    const result = parseSingleFilter(col, opVal, params, paramIdx);
    if (result.filters.length > 0) {
      orParts.push(result.filters[0]);
      params = result.params;
      paramIdx = result.paramIdx;
    }
  }

  if (orParts.length > 0) {
    return { filter: `(${orParts.join(' OR ')})`, params, paramIdx };
  }
  return { filter: null, params, paramIdx };
}

/**
 * Парсинг всех фильтров из query string
 * Обрабатывает: обычные фильтры, or, массивы параметров
 */
function parseFilters(query) {
  const filters = [];
  let params = [];
  let paramIdx = 1;
  const exclude = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns', 'and', 'head']);

  for (const [key, rawValue] of Object.entries(query)) {
    if (exclude.has(key)) continue;
    if (!rawValue) continue;

    // or=(cond1,cond2)
    if (key === 'or') {
      const values = Array.isArray(rawValue) ? rawValue : [rawValue];
      for (const v of values) {
        const result = parseOrFilter(v, params, paramIdx);
        if (result.filter) {
          filters.push(result.filter);
          params = result.params;
          paramIdx = result.paramIdx;
        }
      }
      continue;
    }

    // Обычные фильтры (могут быть массивом при дублировании ключа)
    const values = Array.isArray(rawValue) ? rawValue : [rawValue];
    for (const value of values) {
      const result = parseSingleFilter(key, String(value), params, paramIdx);
      filters.push(...result.filters);
      params = result.params;
      paramIdx = result.paramIdx;
    }
  }

  return {
    where: filters.length ? `WHERE ${filters.join(' AND ')}` : '',
    params,
    nextIdx: paramIdx,
  };
}

/**
 * Парсинг select с поддержкой вложенных таблиц (JOIN)
 * col1,col2,alias:table(col3,col4)
 * alias:table!inner(col3) — inner join
 */
function parseSelect(selectStr, mainTable) {
  if (!selectStr || selectStr === '*') return { columns: '*', joins: [] };

  const parts = [];
  let depth = 0;
  let current = '';
  for (const ch of selectStr) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) {
      parts.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim()) parts.push(current.trim());

  const columns = [];
  for (const part of parts) {
    // alias:table!inner(cols) или alias:table(cols) или table(cols)
    const joinMatch = part.match(/^(\w+):(\w+)(?:!inner)?\(([^)]*)\)$/);
    const simpleJoinMatch = part.match(/^(\w+)\(([^)]*)\)$/);

    if (joinMatch) {
      const [, alias, fTable, fColsStr] = joinMatch;
      const fCols = fColsStr.split(',').map(c => c.trim()).filter(c => /^[a-zA-Z_]\w*$/.test(c));
      if (fCols.length > 0) {
        const jsonParts = fCols.map(c => `'${c}', ft."${c}"`).join(', ');
        // Пробуем alias_id (genre_id) — основной вариант, НЕ используем OR с несуществующей колонкой
        // Для genre:genres — alias=genre → genre_id; для profiles:profiles — alias=profiles → profiles_id (fallback user_id)
        const fkCol = `${alias}_id`;
        columns.push(`(SELECT jsonb_build_object(${jsonParts}) FROM public."${fTable}" ft WHERE ft.id = ${mainTable}."${fkCol}" LIMIT 1) as "${alias}"`);
      }
    } else if (simpleJoinMatch) {
      const [, fTable, fColsStr] = simpleJoinMatch;
      const fCols = fColsStr.split(',').map(c => c.trim()).filter(c => /^[a-zA-Z_]\w*$/.test(c));
      if (fCols.length > 0) {
        const jsonParts = fCols.map(c => `'${c}', ft."${c}"`).join(', ');
        // Singular FK: profiles(username) → table has user_id or profiles_id
        // Try common FK patterns: table_id, then singular form of table + _id
        const singularTable = fTable.endsWith('s') ? fTable.slice(0, -1) : fTable;
        const fkCol = `${singularTable}_id`;
        columns.push(`(SELECT jsonb_build_object(${jsonParts}) FROM public."${fTable}" ft WHERE ft.id = ${mainTable}."${fkCol}" LIMIT 1) as "${fTable}"`);
      }
    } else if (part === '*') {
      columns.push('*');
    } else if (/^[a-zA-Z_][a-zA-Z0-9_.]*$/.test(part)) {
      columns.push(`"${part}"`);
    }
  }

  return { columns: columns.length ? columns.join(', ') : '*', joins: [] };
}

function parseOrder(orderStr) {
  if (!orderStr) return '';
  const parts = orderStr.split(',').map(part => {
    const segments = part.trim().split('.');
    const col = segments[0];
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(col)) return null;
    
    let dir = 'ASC';
    let nulls = '';
    for (let i = 1; i < segments.length; i++) {
      const s = segments[i].toLowerCase();
      if (s === 'desc') dir = 'DESC';
      else if (s === 'asc') dir = 'ASC';
      else if (s === 'nullslast') nulls = ' NULLS LAST';
      else if (s === 'nullsfirst') nulls = ' NULLS FIRST';
    }
    return `"${col}" ${dir}${nulls}`;
  }).filter(Boolean);
  return parts.length ? `ORDER BY ${parts.join(', ')}` : '';
}


// ─── HEAD (count only) ──────────────────────────────────────────
router.head('/:table', async (req, res) => {
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
});


// ─── SELECT ─────────────────────────────────
router.get('/:table', async (req, res) => {
  const client = await pool.connect();
  try {
    // Явная транзакция для корректной работы set_config + auth.uid()
    await client.query('BEGIN');
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

    // Prefer: count=exact
    const prefer = req.headers.prefer || '';
    let countResult = null;
    if (prefer.includes('count=exact')) {
      const countSql = `SELECT COUNT(*) FROM ${table} ${where}`;
      const cr = await client.query(countSql, params);
      countResult = parseInt(cr.rows[0].count);
    }

    const result = await client.query(sql, params);
    await client.query('COMMIT');

    if (countResult !== null) {
      res.set('Content-Range', `0-${result.rows.length}/${countResult}`);
      res.set('X-Total-Count', String(countResult));
    }

    // Supabase .single() / .maybeSingle()
    const acceptHeader = req.headers.accept || '';
    if (acceptHeader.includes('vnd.pgrst.object+json')) {
      return res.json(result.rows[0] || null);
    }

    res.json(result.rows);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST GET]', err.message, '| SQL table:', req.params.table, '| select:', req.query.select);
    // Для несуществующих таблиц/колонок — вернём пустой массив вместо 400
    if (err.message.includes('does not exist') || err.message.includes('column')) {
      return res.json([]);
    }
    res.status(400).json({ message: err.message, error: err.message, code: 'REST_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
});


// ─── INSERT ─────────────────────────────────
router.post('/:table', async (req, res) => {
  const client = await pool.connect();
  try {
    // Явная транзакция для корректной работы set_config + auth.uid()
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const table = sanitizeTable(req.params.table);
    const rows = Array.isArray(req.body) ? req.body : [req.body];
    if (rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'No data' });
    }

    const results = [];
    for (const row of rows) {
      // A2: Sanitize column names to prevent SQL injection via JSON keys
      const cols = Object.keys(row).filter(c => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c));
      if (cols.length === 0) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'No valid columns' });
      }

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
        // A2: Sanitize on_conflict column names
        const conflictCols = onConflict.split(',')
          .map(c => c.trim())
          .filter(c => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c))
          .map(c => `"${c}"`).join(', ');
        if (!conflictCols) {
          await client.query('ROLLBACK');
          return res.status(400).json({ error: 'Invalid on_conflict columns' });
        }
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

    // Если есть select с JOIN-подзапросами, дообогащаем результаты
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
            // Replace results with enriched data (preserves insert order)
            const enrichMap = new Map(enrichResult.rows.map(r => [r.id, r]));
            for (let i = 0; i < results.length; i++) {
              if (results[i].id && enrichMap.has(results[i].id)) {
                results[i] = enrichMap.get(results[i].id);
              }
            }
          }
        }
      } catch (enrichErr) {
        // Non-critical: return basic results if enrichment fails
        console.warn('[REST POST] Select enrichment failed:', enrichErr.message);
      }
    }

    await client.query('COMMIT');

    const prefer = req.headers.prefer || '';
    if (prefer.includes('return=representation')) {
      return res.status(201).json(rows.length === 1 ? results[0] : results);
    }
    res.status(201).json(results);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST POST]', err.message, '| table:', req.params.table);
    res.status(400).json({ message: err.message, error: err.message, code: 'REST_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
});


// ─── UPDATE ─────────────────────────────────
router.patch('/:table', async (req, res) => {
  const client = await pool.connect();
  try {
    // Явная транзакция для корректной работы set_config + auth.uid()
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const table = sanitizeTable(req.params.table);
    const updates = req.body;
    // A2: Sanitize column names in PATCH
    const cols = Object.keys(updates).filter(c => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(c));
    if (cols.length === 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'No valid columns' });
    }

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
      return res.json(result.rows);
    }
    res.status(204).end();
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST PATCH]', err.message);
    res.status(400).json({ message: err.message, error: err.message, code: 'REST_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
});


// ─── DELETE ─────────────────────────────────
router.delete('/:table', async (req, res) => {
  const client = await pool.connect();
  try {
    // Явная транзакция для корректной работы set_config + auth.uid()
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
      return res.json(result.rows);
    }
    res.status(204).end();
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST DELETE]', err.message);
    res.status(400).json({ message: err.message, error: err.message, code: 'REST_ERROR', details: null, hint: null });
  } finally {
    client.release();
  }
});

export default router;
