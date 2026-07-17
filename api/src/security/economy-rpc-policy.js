const ADMIN_ONLY_RPC = new Set([
  'add_user_credits',
  'admin_add_xp',
  'admin_grant_user_income',
  'calculate_chart_scores',
  'calculate_track_quality',
  'deduct_user_xp',
  'fn_add_xp',
  'get_economy_health',
  'get_referral_overview',
  'process_payment_refund',
  'process_payout_request',
  'update_referral_settings',
]);

const SERVICE_ROLE_ONLY_RPC = new Set([
  'award_xp',
  'process_payment_completion',
  'refund_generation_failed',
  'safe_award_xp',
]);

const AUTHENTICATED_RPC = new Set([
  'check_user_achievements',
  'debit_balance',
  'debit_for_generation',
  'get_creator_earnings_profile',
  'get_my_referral_stats',
  'get_or_create_referral_code',
  'radio_award_listen_xp',
  'register_referral',
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

function roleOf(user) {
  return String(user?.app_role || '').toLowerCase();
}

export function isEconomyRpcAdmin(user) {
  return user?.role === 'service_role'
    || ['admin', 'super_admin', 'superadmin'].includes(roleOf(user));
}

function requireAuthenticated(user) {
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
}

export function assertEconomyRpcAccess(fnName, user, params = {}) {
  if (SERVICE_ROLE_ONLY_RPC.has(fnName)) {
    if (user?.role !== 'service_role') {
      throw httpError(403, 'Service role required', 'SERVICE_ROLE_REQUIRED');
    }
    return params;
  }

  if (ADMIN_ONLY_RPC.has(fnName)) {
    requireAuthenticated(user);
    if (!isEconomyRpcAdmin(user)) {
      throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
    }
    return params;
  }

  if (!AUTHENTICATED_RPC.has(fnName)) return params;
  requireAuthenticated(user);

  if (user.role !== 'service_role') {
    if (fnName === 'check_user_achievements'
        || fnName === 'debit_balance'
        || fnName === 'debit_for_generation'
        || fnName === 'get_creator_earnings_profile'
        || fnName === 'get_or_create_referral_code'
        || fnName === 'radio_award_listen_xp'
        || fnName === 'register_referral') {
      // Never trust a client-supplied identity. Binding also handles omitted
      // ids and closes IDOR without relying on the SQL function implementation.
      if (fnName === 'register_referral') {
        params.p_referee_id = user.id;
        delete params.p_user_id;
      } else {
        params.p_user_id = user.id;
      }
      delete params.user_uuid;
    }
  }

  return params;
}

export const ECONOMY_SERVICE_ROLE_ONLY_RPC = SERVICE_ROLE_ONLY_RPC;
