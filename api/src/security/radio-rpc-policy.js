const RADIO_ADMIN_RPC = new Set([
  'admin_set_radio_queue_override',
  'admin_update_radio_config',
  'get_l2e_admin_stats',
  'radio_create_next_slot',
  'radio_resolve_predictions',
]);

function isAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function assertRadioRpcAccess(fnName, user) {
  if (!RADIO_ADMIN_RPC.has(fnName)) return;
  if (!user?.id || user.role === 'anon') {
    const error = new Error('Authentication required');
    error.status = 401;
    error.code = 'AUTH_REQUIRED';
    throw error;
  }
  if (!isAdmin(user)) {
    const error = new Error('Administrator access required');
    error.status = 403;
    error.code = 'ADMIN_REQUIRED';
    throw error;
  }
}
