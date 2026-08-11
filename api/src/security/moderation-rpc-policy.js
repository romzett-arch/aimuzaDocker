const STAFF_ONLY_RPC = new Set([
  'close_voting_topic_on_rejection',
  'get_admin_moderation_history',
  'get_admin_moderation_stats',
  'moderate_track',
  'request_track_copyright_evidence',
  'resolve_copyright_request',
]);

const AUTHENTICATED_RPC = new Set([
  'respond_copyright_request',
  'submit_track_for_moderation',
]);

function isStaff(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  if (['admin', 'super_admin', 'superadmin'].includes(role)) return true;
  return role === 'moderator' && user?.permissions?.includes('moderation');
}

export function assertModerationRpcAccess(fnName, user) {
  if (STAFF_ONLY_RPC.has(fnName) && !isStaff(user)) {
    const error = new Error('Требуются права модератора');
    error.status = user?.id ? 403 : 401;
    error.code = 'MODERATION_STAFF_REQUIRED';
    throw error;
  }
  if (AUTHENTICATED_RPC.has(fnName) && !user?.id) {
    const error = new Error('Необходимо войти в систему');
    error.status = 401;
    error.code = 'AUTH_REQUIRED';
    throw error;
  }
}
