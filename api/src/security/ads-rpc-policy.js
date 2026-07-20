const PUBLIC_RPC = new Set([
  'get_public_ad_settings',
  'request_ad_for_slot',
  'record_ad_impression_v2',
  'record_ad_click_v2',
  'record_ad_view_duration_v2',
  'radio_record_ad_event',
]);

const AUTHENTICATED_RPC = new Set([
  'purchase_ad_free',
  'radio_skip_ad_v2',
]);

const ADMIN_RPC = new Set([
  'admin_set_ad_campaign_slots',
  'admin_set_ad_campaign_status',
  'get_ad_campaign_readiness',
]);

const LEGACY_SERVICE_ONLY_RPC = new Set([
  'get_ad_for_slot',
  'record_ad_impression',
  'record_ad_click',
  'radio_skip_ad',
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

function isAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return ['admin', 'super_admin', 'superadmin'].includes(role);
}

function requireAuthenticated(user) {
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
}

export function assertAdsRpcAccess(fnName, user, params = {}) {
  if (PUBLIC_RPC.has(fnName)) return params;

  if (LEGACY_SERVICE_ONLY_RPC.has(fnName)) {
    if (user?.role !== 'service_role') {
      throw httpError(403, 'Legacy advertising RPC is disabled', 'LEGACY_RPC_DISABLED');
    }
    return params;
  }

  if (ADMIN_RPC.has(fnName)) {
    requireAuthenticated(user);
    if (!isAdmin(user)) {
      throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
    }
    return params;
  }

  if (!AUTHENTICATED_RPC.has(fnName)) return params;
  requireAuthenticated(user);

  if (fnName === 'purchase_ad_free' && user.role !== 'service_role') {
    params.p_user_id = user.id;
  }
  return params;
}
