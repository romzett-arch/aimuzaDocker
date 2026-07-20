/**
 * Authorization boundary for Interactive Radio REST tables.
 * The gateway connects as DB owner, so these rules are mandatory in addition to RLS.
 */

const RADIO_TABLES = new Set([
  'radio_ad_breaks', 'radio_ad_events', 'radio_ad_placements',
  'radio_bids', 'radio_config', 'radio_listeners', 'radio_listens',
  'radio_predictions', 'radio_queue', 'radio_queue_overrides',
  'radio_schedule', 'radio_slots',
]);

const OWNER_READ_TABLES = new Set(['radio_listens', 'radio_predictions']);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

export function isRadioAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function getRadioReadScope(table, user, startIndex = 1) {
  if (!OWNER_READ_TABLES.has(table) || isRadioAdmin(user)) return { sql: '', params: [] };
  if (!user?.id || user.role === 'anon') return { sql: 'FALSE', params: [] };
  return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
}

export function assertRadioMutationAccess(table, user) {
  if (!RADIO_TABLES.has(table)) return;
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
  if (!isRadioAdmin(user)) {
    throw httpError(403, 'Radio tables are changed through protected RPC only', 'RADIO_RPC_REQUIRED');
  }
}
