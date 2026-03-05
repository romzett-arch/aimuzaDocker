export async function setJwtClaims(client, user) {
  if (user && user.id && user.id !== 'service-role') {
    await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [user.id]);
    await client.query(`SELECT set_config('request.jwt.claim.role', $1, true)`, [user.role || 'authenticated']);
    if (user.email) {
      await client.query(`SELECT set_config('request.jwt.claim.email', $1, true)`, [user.email]);
    }
  }
}

export async function resetJwtClaims(client) {
  await client.query(`SELECT set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claim.role', '', true), set_config('request.jwt.claim.email', '', true)`).catch(() => {});
}

export function sanitizeTable(name) {
  if (!/^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(name)) throw new Error('Invalid table name');
  const pgName = name.replace(/-/g, '_');
  return `public."${pgName}"`;
}

export function sanitizeCol(col) {
  if (!/^[a-zA-Z_][a-zA-Z0-9_.]*$/.test(col)) return null;
  return `"${col}"`;
}

export function parseSingleFilter(col, value, params, paramIdx) {
  const filters = [];
  const sc = sanitizeCol(col);
  if (!sc) return { filters, params, paramIdx };

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
        filters.push('FALSE');
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
    case 'cs':
      filters.push(`${sc} @> $${paramIdx}::jsonb`); params.push(val); paramIdx++; break;
    case 'cd':
      filters.push(`${sc} <@ $${paramIdx}::jsonb`); params.push(val); paramIdx++; break;
    case 'fts': case 'plfts': case 'phfts': case 'wfts':
      filters.push(`${sc} @@ to_tsquery($${paramIdx})`); params.push(val); paramIdx++; break;
  }

  return { filters, params, paramIdx };
}

export function parseOrFilter(value, params, paramIdx) {
  const inner = value.replace(/^\(|\)$/g, '');
  const conditions = [];

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

export function parseFilters(query) {
  const filters = [];
  let params = [];
  let paramIdx = 1;
  const exclude = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns', 'and', 'head']);

  for (const [key, rawValue] of Object.entries(query)) {
    if (exclude.has(key)) continue;
    if (!rawValue) continue;

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

export function parseSelect(selectStr, mainTable) {
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
    const joinMatch = part.match(/^(\w+):(\w+)(?:!inner)?\(([^)]*)\)$/);
    const simpleJoinMatch = part.match(/^(\w+)\(([^)]*)\)$/);

    if (joinMatch) {
      const [, alias, fTable, fColsStr] = joinMatch;
      const fCols = fColsStr.split(',').map(c => c.trim()).filter(c => /^[a-zA-Z_]\w*$/.test(c));
      if (fCols.length > 0) {
        const jsonParts = fCols.map(c => `'${c}', ft."${c}"`).join(', ');
        const fkCol = `${alias}_id`;
        columns.push(`(SELECT jsonb_build_object(${jsonParts}) FROM public."${fTable}" ft WHERE ft.id = ${mainTable}."${fkCol}" LIMIT 1) as "${alias}"`);
      }
    } else if (simpleJoinMatch) {
      const [, fTable, fColsStr] = simpleJoinMatch;
      const fCols = fColsStr.split(',').map(c => c.trim()).filter(c => /^[a-zA-Z_]\w*$/.test(c));
      if (fCols.length > 0) {
        const jsonParts = fCols.map(c => `'${c}', ft."${c}"`).join(', ');
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

export function parseOrder(orderStr) {
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
