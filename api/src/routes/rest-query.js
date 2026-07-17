import { pool } from '../db.js';
import { setJwtClaims, resetJwtClaims, sanitizeTable, parseFilters, parseSelect, parseOrder } from './rest-utils.js';
import { getForumReadColumns, getForumReadScope } from '../security/forum-rest-policy.js';
import { getMarketplaceReadScope } from '../security/marketplace-rest-policy.js';
import { getEventsReadScope } from '../security/events-rest-policy.js';
import { assertEconomyReadAccess, getEconomyReadScope } from '../security/economy-rest-policy.js';
import { assertSupportQaReadAccess, getSupportQaReadScope } from '../security/support-qa-rest-policy.js';
import { getMusicReadScope } from '../security/music-rest-policy.js';
import { getGalleryReadScope } from '../security/gallery-rest-policy.js';

function addScope(where, scopeSql) {
  if (!scopeSql) return where;
  return where ? `${where} AND ${scopeSql}` : `WHERE ${scopeSql}`;
}

export async function handleHead(req, res) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const table = sanitizeTable(req.params.table);
    assertEconomyReadAccess(req.params.table, req.user);
    assertSupportQaReadAccess(req.params.table, req.user);
    const { where, params } = parseFilters(req.query);
    const scope = getForumReadScope(req.params.table, req.user, params.length + 1);
    const marketplaceScope = getMarketplaceReadScope(req.params.table, req.user, params.length + scope.params.length + 1);
    const eventsScope = getEventsReadScope(req.params.table, req.user, params.length + scope.params.length + marketplaceScope.params.length + 1);
    const economyScope = getEconomyReadScope(req.params.table, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + 1);
    const supportQaScope = getSupportQaReadScope(req.params.table, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + economyScope.params.length + 1);
    const musicScope = getMusicReadScope(req.params.table, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + economyScope.params.length + supportQaScope.params.length + 1);
    const galleryScope = getGalleryReadScope(req.params.table, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + economyScope.params.length + supportQaScope.params.length + musicScope.params.length + 1);
    const scopedWhere = addScope(addScope(addScope(addScope(addScope(addScope(addScope(where, scope.sql), marketplaceScope.sql), eventsScope.sql), economyScope.sql), supportQaScope.sql), musicScope.sql), galleryScope.sql);
    const countSql = `SELECT COUNT(*) FROM ${table} ${scopedWhere}`;
    const cr = await client.query(countSql, [...params, ...scope.params, ...marketplaceScope.params, ...eventsScope.params, ...economyScope.params, ...supportQaScope.params, ...musicScope.params, ...galleryScope.params]);

    await client.query('COMMIT');
    res.set('Content-Range', `0-0/${cr.rows[0].count}`);
    res.set('X-Total-Count', String(cr.rows[0].count));
    res.status(200).end();
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST HEAD]', err.message);
    res.status(200).set('Content-Range', '0-0/0').set('X-Total-Count', '0').end();
  } finally {
    await resetJwtClaims(client);
    client.release();
  }
}

export async function handleGet(req, res) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await setJwtClaims(client, req.user);

    const tableName = req.params.table;
    const table = sanitizeTable(tableName);
    assertEconomyReadAccess(tableName, req.user);
    assertSupportQaReadAccess(tableName, req.user);
    const parsedSelect = parseSelect(req.query.select, table);
    const columns = getForumReadColumns(tableName, req.user, parsedSelect.columns);
    const { where, params } = parseFilters(req.query);
    const scope = getForumReadScope(tableName, req.user, params.length + 1);
    const marketplaceScope = getMarketplaceReadScope(tableName, req.user, params.length + scope.params.length + 1);
    const eventsScope = getEventsReadScope(tableName, req.user, params.length + scope.params.length + marketplaceScope.params.length + 1);
    const economyScope = getEconomyReadScope(tableName, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + 1);
    const supportQaScope = getSupportQaReadScope(tableName, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + economyScope.params.length + 1);
    const musicScope = getMusicReadScope(tableName, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + economyScope.params.length + supportQaScope.params.length + 1);
    const galleryScope = getGalleryReadScope(tableName, req.user, params.length + scope.params.length + marketplaceScope.params.length + eventsScope.params.length + economyScope.params.length + supportQaScope.params.length + musicScope.params.length + 1);
    const scopedWhere = addScope(addScope(addScope(addScope(addScope(addScope(addScope(where, scope.sql), marketplaceScope.sql), eventsScope.sql), economyScope.sql), supportQaScope.sql), musicScope.sql), galleryScope.sql);
    const scopedParams = [...params, ...scope.params, ...marketplaceScope.params, ...eventsScope.params, ...economyScope.params, ...supportQaScope.params, ...musicScope.params, ...galleryScope.params];
    const order = parseOrder(req.query.order);
    const limit = parseInt(req.query.limit) || null;
    const offset = parseInt(req.query.offset) || 0;

    let sql = `SELECT ${columns} FROM ${table} ${scopedWhere} ${order}`;
    if (limit) sql += ` LIMIT ${limit}`;
    if (offset) sql += ` OFFSET ${offset}`;

    const prefer = req.headers.prefer || '';
    let countResult = null;
    if (prefer.includes('count=exact')) {
      const countSql = `SELECT COUNT(*) FROM ${table} ${scopedWhere}`;
      const cr = await client.query(countSql, scopedParams);
      countResult = parseInt(cr.rows[0].count);
    }

    const result = await client.query(sql, scopedParams);

    await client.query('COMMIT');

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
    await client.query('ROLLBACK').catch(() => {});
    console.error('[REST GET]', err.message, '| SQL table:', req.params.table, '| select:', req.query.select);
    if (err.message.includes('does not exist') || err.message.includes('column')) {
      return res.json([]);
    }
    res.status(err.status || 400).json({
      message: err.message,
      error: err.message,
      code: err.code || 'REST_ERROR',
      details: null,
      hint: null,
    });
  } finally {
    await resetJwtClaims(client);
    client.release();
  }
}
