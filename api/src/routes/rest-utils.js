import { coreScope, assertJoinColumns } from '../security/core-rest-policy.js';
export async function setJwtClaims(client,user) {
 const role = user?.role==='service_role' ? 'service_role' : user?.id ? 'authenticated' : 'anon';
 await client.query('SET LOCAL ROLE '+role);
 const sub=user?.id && user.id!=='service-role' ? user.id : '';
 await client.query(`SELECT set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claim.role',$2,true),set_config('request.jwt.claim.email',$3,true),set_config('request.jwt.claims',$4,true)`,[sub,role,user?.email||'',JSON.stringify({sub,role,email:user?.email||''})]);
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
  if (!sc || typeof value !== 'string' || value.length>8192) throw Object.assign(new Error('Invalid filter'),{status:400});

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
    if (!filters.length) throw Object.assign(new Error('Unsupported filter'),{status:400});
    return { filters, params, paramIdx };
  }

  const match = value.match(/^(eq|neq|gt|gte|lt|lte|like|ilike|is|in|cs|cd|ov|fts|plfts|phfts|wfts)\.(.*)$/s);
  if (!match) throw Object.assign(new Error('Unsupported filter'),{status:400});

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

  if (!filters.length) throw Object.assign(new Error('Unsupported filter'),{status:400});
  return { filters, params, paramIdx };
}

export function parseOrFilter(value, params, paramIdx, join='OR', nesting=0) {
  if (typeof value!=='string' || value.length>8192 || nesting>5 || !value.startsWith('(') || !value.endsWith(')')) throw Object.assign(new Error('Invalid logical filter'),{status:400});
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
  if (depth!==0 || !conditions.length || conditions.length>100) throw Object.assign(new Error('Invalid logical filter'),{status:400});

  const orParts = [];
  for (const cond of conditions) {
    const logical=cond.match(/^(and|or)\.(\(.*\))$/s);
    if(logical) { const nested=parseOrFilter(logical[2],params,paramIdx,logical[1].toUpperCase(),nesting+1);orParts.push(nested.filter);params=nested.params;paramIdx=nested.paramIdx;continue; }
    const dotIdx = cond.indexOf('.');
    if (dotIdx === -1) throw Object.assign(new Error('Invalid logical filter'),{status:400});
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
    return { filter: `(${orParts.join(` ${join} `)})`, params, paramIdx };
  }
  return { filter: null, params, paramIdx };
}

export function parseFilters(query) {
  const filters = [];
  let params = [];
  let paramIdx = 1;
  const exclude = new Set(['select', 'order', 'limit', 'offset', 'on_conflict', 'columns', 'head']);
  if(Object.keys(query).length>100) throw Object.assign(new Error('Too many filters'),{status:400});

  for (const [key, rawValue] of Object.entries(query)) {
    if (exclude.has(key)) continue;
    if (!rawValue) throw Object.assign(new Error('Empty filter'),{status:400});

    if (key === 'or' || key === 'and') {
      const values = Array.isArray(rawValue) ? rawValue : [rawValue];
      for (const v of values) {
        const result = parseOrFilter(v, params, paramIdx,key.toUpperCase());
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

export function parseSelect(selectStr, mainTable, user) {
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
    const joinMatch = part.match(/^(\w+):(\w+)(?:![\w_]+)?\(([^)]*)\)$/);
    const simpleJoinMatch = part.match(/^(\w+)(?:!inner)?\(([^)]*)\)$/);

    if (joinMatch) {
      const [, alias, rawTable, fColsStr] = joinMatch;
      const fTable = rawTable === "user_id" && alias === "profiles" ? "profiles" : rawTable;
      const fCols = fColsStr.split(',').map(c => c.trim()).filter(c => /^[a-zA-Z_]\w*$/.test(c));
      if (fCols.length > 0) {
        assertJoinColumns(fTable,fCols,user);
        const jsonParts = fCols.map(c => `'${c}', ft."${c}"`).join(', ');
        const fkCol = fTable === "profiles" ? "user_id" : `${alias}_id`;
        const targetKey = fTable === "profiles" ? "user_id" : "id";
        columns.push(`(SELECT jsonb_build_object(${jsonParts}) FROM public."${fTable}" ft WHERE ft."${targetKey}" = ${mainTable}."${fkCol}" LIMIT 1) as "${alias}"`);
      }
    } else if (simpleJoinMatch) {
      const [, fTable, fColsStr] = simpleJoinMatch;
      const fCols = fColsStr.split(',').map(c => c.trim()).filter(c => /^[a-zA-Z_]\w*$/.test(c));
      if (fCols.length > 0) {
        assertJoinColumns(fTable,fCols,user);
        const jsonParts = fCols.map(c => `'${c}', ft."${c}"`).join(', ');
        const baseTable = fTable.replace(/^forum_/, '');
        const singularTable = baseTable.endsWith('ies')
          ? `${baseTable.slice(0, -3)}y`
          : (baseTable.endsWith('s') ? baseTable.slice(0, -1) : baseTable);
        const fkCol = fTable==='profiles' ? 'user_id' : `${singularTable}_id`;
        const targetKey = fTable==='profiles' ? 'user_id' : 'id';
        columns.push(`(SELECT jsonb_build_object(${jsonParts}) FROM public."${fTable}" ft WHERE ft."${targetKey}" = ${mainTable}."${fkCol}" LIMIT 1) as "${fTable}"`);
      }
    } else if (part === '*') {
      columns.push('*');
    } else if (/^[a-zA-Z_][a-zA-Z0-9_.]*$/.test(part)) {
      columns.push(`"${part}"`);
    }
  }

  if (!columns.length) throw Object.assign(new Error('Invalid selection'),{status:400});
  return { columns: columns.join(', '), joins: [] };
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

export function parseScopedFilters(query,table,user) {
 const parsed=parseFilters(query);
 const scope=coreScope(table,user,parsed.params.length+1);
 return {...parsed,where:scope.sql ? (parsed.where ? parsed.where+' AND '+scope.sql : 'WHERE '+scope.sql) : parsed.where,params:[...parsed.params,...scope.params]};
}
