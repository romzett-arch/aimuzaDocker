/**
 * Authorization policy for economy, progression and referral tables.
 *
 * The custom API uses a database-owner connection, so PostgreSQL RLS cannot
 * be the only authorization boundary. Every table listed here must have an
 * explicit read and mutation policy.
 */

const PUBLIC_READ_TABLES = new Set([
  'achievements',
  'reputation_tiers',
  'xp_event_config',
]);

const AUTHENTICATED_READ_TABLES = new Set([
  'referral_settings',
]);

const ADMIN_READ_TABLES = new Set([
  'attribution_pools',
  'economy_config',
  'economy_snapshots',
]);

const OWNER_COLUMNS = new Map([
  ['attribution_shares', 'user_id'],
  ['creator_earnings', 'user_id'],
  ['referral_codes', 'user_id'],
  ['referral_rewards', 'user_id'],
  ['referral_stats', 'user_id'],
  ['reputation_events', 'user_id'],
  ['track_quality_scores', 'user_id'],
  ['user_achievements', 'user_id'],
]);

const ECONOMY_TABLES = new Set([
  ...PUBLIC_READ_TABLES,
  ...AUTHENTICATED_READ_TABLES,
  ...ADMIN_READ_TABLES,
  ...OWNER_COLUMNS.keys(),
  'referrals',
]);

const REFERRAL_CODE_USER_UPDATE_COLUMNS = new Set(['custom_code']);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

function requireAuthenticated(user) {
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
}

export function isEconomyTable(table) {
  return ECONOMY_TABLES.has(table);
}

export function isEconomyAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function assertEconomyReadAccess(table, user) {
  if (!isEconomyTable(table) || PUBLIC_READ_TABLES.has(table) || isEconomyAdmin(user)) return;
  requireAuthenticated(user);
  if (ADMIN_READ_TABLES.has(table)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }
}

export function getEconomyReadScope(table, user, startIndex = 1) {
  if (!isEconomyTable(table) || PUBLIC_READ_TABLES.has(table)
      || AUTHENTICATED_READ_TABLES.has(table) || isEconomyAdmin(user)) {
    return { sql: '', params: [] };
  }

  if (ADMIN_READ_TABLES.has(table)) return { sql: 'FALSE', params: [] };

  const ownerColumn = OWNER_COLUMNS.get(table);
  if (ownerColumn) {
    return { sql: `"${ownerColumn}" = $${startIndex}`, params: [user.id] };
  }
  if (table === 'referrals') {
    return {
      sql: `("referrer_id" = $${startIndex} OR "referred_id" = $${startIndex})`,
      params: [user.id],
    };
  }
  return { sql: 'FALSE', params: [] };
}

export function assertEconomyMutationAccess(table, user, operation) {
  if (!isEconomyTable(table)) return;
  requireAuthenticated(user);
  if (isEconomyAdmin(user)) return;

  // A user may only rename their own referral code. Creation is performed by
  // get_or_create_referral_code; counters and reward state are server-owned.
  if (table === 'referral_codes' && operation === 'update') return;
  throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
}

export function filterEconomyMutationColumns(table, columns, user, operation) {
  if (!isEconomyTable(table) || isEconomyAdmin(user)) return columns;
  if (table === 'referral_codes' && operation === 'update') {
    return columns.filter(column => REFERRAL_CODE_USER_UPDATE_COLUMNS.has(column));
  }
  return [];
}

export function getEconomyMutationScope(table, user, startIndex = 1) {
  if (!isEconomyTable(table) || isEconomyAdmin(user)) return { sql: '', params: [] };
  if (table === 'referral_codes') {
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }
  return { sql: 'FALSE', params: [] };
}
