/**
 * Authorization boundary for display and radio advertising tables.
 *
 * The REST gateway connects as the database owner, so PostgreSQL RLS is not
 * sufficient here. Advertising configuration, raw events and placements are
 * deliberately admin-only; public delivery goes through narrowly scoped RPCs.
 */

const ADS_TABLES = new Set([
  'ad_campaigns',
  'ad_campaign_slots',
  'ad_creatives',
  'ad_deliveries',
  'ad_impressions',
  'ad_settings',
  'ad_slots',
  'ad_targeting',
  'radio_ad_events',
  'radio_ad_breaks',
  'radio_ad_placements',
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

export function isAdsAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function isAdsTable(table) {
  return ADS_TABLES.has(table);
}

function assertAdmin(table, user) {
  if (!isAdsTable(table)) return;
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
  if (!isAdsAdmin(user)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }
}

export function assertAdsReadAccess(table, user) {
  assertAdmin(table, user);
}

export function assertAdsMutationAccess(table, user, operation, payload = {}) {
  assertAdmin(table, user);
  if (table === 'ad_campaigns' && operation === 'update' && Object.prototype.hasOwnProperty.call(payload, 'status')) {
    throw httpError(409, 'Campaign status is changed through readiness-checked RPC only', 'AD_STATUS_RPC_REQUIRED');
  }
}
