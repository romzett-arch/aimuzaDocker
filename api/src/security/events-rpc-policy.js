const ADMIN_RPCS = new Set([
  'award_contest_prize', 'cancel_contest', 'finalize_contest', 'finalize_contest_winners',
  'process_contest_lifecycle',
]);

const AUTH_RPCS = new Set(['submit_contest_entry', 'withdraw_contest_entry']);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

function isAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function assertEventsRpcAccess(fnName, user, params) {
  if (!ADMIN_RPCS.has(fnName) && !AUTH_RPCS.has(fnName)) return;
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
  if (ADMIN_RPCS.has(fnName) && !isAdmin(user)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }
  if (fnName === 'submit_contest_entry' && user.role !== 'service_role') {
    params.p_user_id = user.id;
  }
}
