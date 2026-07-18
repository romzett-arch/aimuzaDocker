/**
 * Authorization policy for Marketplace tables exposed by the custom REST API.
 *
 * The API connects as the database owner, which bypasses ordinary PostgreSQL
 * RLS. These checks are therefore mandatory in addition to database policies.
 */

const MARKETPLACE_TABLES = new Set([
  'item_purchases',
  'lyrics_items',
  'store_items',
  'user_prompts',
]);

const IMMUTABLE_COLUMNS = new Map([
  ['item_purchases', new Set([
    'id', 'buyer_id', 'seller_id', 'store_item_id', 'item_type', 'source_id',
    'price', 'license_type', 'platform_fee', 'net_amount', 'status',
    'admin_status', 'reviewed_by', 'reviewed_at', 'created_at',
    'license_terms_snapshot', 'license_agreement_hash', 'license_accepted_at',
    'agreement_number', 'guarantee_status',
  ])],
  ['store_items', new Set([
    'id', 'seller_id', 'user_id', 'item_type', 'source_id', 'sales_count',
    'views_count', 'created_at',
  ])],
  ['user_prompts', new Set(['id', 'user_id', 'downloads_count', 'created_at'])],
  ['lyrics_items', new Set([
    'id', 'user_id', 'sales_count', 'views_count', 'downloads_count', 'created_at',
  ])],
]);

const INSERT_PROTECTED_COLUMNS = new Map([
  ['item_purchases', IMMUTABLE_COLUMNS.get('item_purchases')],
  ['store_items', new Set(['id', 'sales_count', 'views_count', 'created_at'])],
  ['user_prompts', new Set(['id', 'downloads_count', 'created_at'])],
  ['lyrics_items', new Set(['id', 'sales_count', 'views_count', 'downloads_count', 'created_at'])],
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

export function isMarketplaceTable(table) {
  return MARKETPLACE_TABLES.has(table);
}

export function isMarketplaceAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

function requireAuthenticated(user) {
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
}

export function getMarketplaceReadScope(table, user, startIndex = 1) {
  if (!isMarketplaceTable(table) || isMarketplaceAdmin(user)) {
    return { sql: '', params: [] };
  }

  if (table === 'store_items') {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return {
      sql: `store_items.seller_id = $${startIndex}`,
      params: [user.id],
    };
  }

  if (table === 'item_purchases') {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return {
      sql: `(item_purchases.buyer_id = $${startIndex} OR item_purchases.seller_id = $${startIndex})`,
      params: [user.id],
    };
  }

  if (table === 'user_prompts') {
    const freePublic = `(user_prompts.is_public IS TRUE AND COALESCE(user_prompts.price, 0) = 0)`;
    if (!user?.id) return { sql: freePublic, params: [] };
    return {
      sql: `(
        user_prompts.user_id = $${startIndex}
        OR ${freePublic}
        OR EXISTS (
          SELECT 1
          FROM public.item_purchases ip
          WHERE ip.buyer_id = $${startIndex}
            AND ip.item_type = 'prompt'
            AND ip.source_id = user_prompts.id
            AND COALESCE(ip.admin_status, 'approved') = 'approved'
        )
      )`,
      params: [user.id],
    };
  }

  if (table === 'lyrics_items') {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return {
      sql: `(
        lyrics_items.user_id = $${startIndex}
        OR EXISTS (
          SELECT 1
          FROM public.item_purchases ip
          WHERE ip.buyer_id = $${startIndex}
            AND ip.item_type = 'lyrics'
            AND ip.source_id = lyrics_items.id
            AND COALESCE(ip.admin_status, 'approved') = 'approved'
        )
      )`,
      params: [user.id],
    };
  }

  return { sql: '', params: [] };
}

export function assertMarketplaceMutationAccess(table, user) {
  if (!isMarketplaceTable(table)) return;
  requireAuthenticated(user);

  if (table === 'item_purchases' && !isMarketplaceAdmin(user)) {
    throw httpError(403, 'Purchases can only be created through the purchase RPC', 'MARKETPLACE_RPC_REQUIRED');
  }
}

export function applyMarketplaceInsertOwnership(table, row, user) {
  if (!isMarketplaceTable(table) || isMarketplaceAdmin(user)) return row;
  if (table === 'store_items') return { ...row, seller_id: user.id, user_id: user.id };
  if (table === 'user_prompts' || table === 'lyrics_items') return { ...row, user_id: user.id };
  return row;
}

export function filterMarketplaceMutationColumns(table, columns, user, isInsert = false) {
  if (!isMarketplaceTable(table) || isMarketplaceAdmin(user)) return columns;
  const protectedColumns = (isInsert ? INSERT_PROTECTED_COLUMNS : IMMUTABLE_COLUMNS).get(table) || new Set();
  return columns.filter(column => !protectedColumns.has(column));
}

export function getMarketplaceMutationScope(table, user, startIndex = 1) {
  if (!isMarketplaceTable(table) || isMarketplaceAdmin(user)) {
    return { sql: '', params: [] };
  }
  requireAuthenticated(user);

  if (table === 'store_items') {
    return { sql: `store_items.seller_id = $${startIndex}`, params: [user.id] };
  }
  if (table === 'user_prompts' || table === 'lyrics_items') {
    return { sql: `${table}.user_id = $${startIndex}`, params: [user.id] };
  }
  return { sql: 'FALSE', params: [] };
}

export async function assertMarketplaceInsertRelation(client, table, row, user) {
  if (table !== 'store_items' || isMarketplaceAdmin(user)) return;

  if (row.item_type === 'prompt') {
    throw httpError(400, 'Prompt sales are disabled', 'PROMPT_SALES_DISABLED');
  }
  if (row.item_type !== 'lyrics') {
    throw httpError(400, 'Unsupported Marketplace item type', 'INVALID_ITEM_TYPE');
  }
  if (!row.source_id) {
    throw httpError(400, 'Marketplace source is required', 'SOURCE_REQUIRED');
  }
  if (!Number.isInteger(row.price) || row.price < 0) {
    throw httpError(400, 'Marketplace price must be a non-negative integer', 'INVALID_PRICE');
  }

  const sourceTable = row.item_type === 'prompt' ? 'user_prompts' : 'lyrics_items';
  const result = await client.query(
    `SELECT 1 FROM public.${sourceTable} WHERE id = $1 AND user_id = $2`,
    [row.source_id, user.id],
  );
  if (result.rowCount !== 1) {
    throw httpError(403, 'Marketplace source does not belong to the seller', 'SOURCE_OWNERSHIP_REQUIRED');
  }
}
