const ADMIN_ONLY_RPC = new Set([
  'forum_admin_delete_category',
  'forum_admin_merge_tags',
  'forum_admin_reorder_categories',
  'forum_admin_list_users',
  'forum_get_hub_stats',
  'forum_moderate_promo',
]);

const STAFF_ONLY_RPC = new Set([
  'delete_forum_topic_cascade',
  'forum_issue_sanction',
  'forum_lift_sanction',
  'forum_resolve_report',
]);

const AUTHENTICATED_RPC = new Set([
  'forum_boost_topic',
  'forum_calculate_content_quality',
  'forum_mark_read',
  'forum_mark_solution',
  'forum_purchase_promo',
  'forum_purchase_premium_content',
  'forum_recalculate_authority',
]);

function roleOf(user) {
  return String(user?.app_role || '').toLowerCase();
}

export function isForumRpcAdmin(user) {
  return user?.role === 'service_role'
    || ['admin', 'super_admin', 'superadmin'].includes(roleOf(user));
}

export function isForumRpcStaff(user) {
  return isForumRpcAdmin(user) || roleOf(user) === 'moderator';
}

export function assertForumRpcAccess(fnName, user, params = {}) {
  if (ADMIN_ONLY_RPC.has(fnName) && !isForumRpcAdmin(user)) {
    const error = new Error('Требуются права администратора');
    error.status = user?.id ? 403 : 401;
    throw error;
  }

  if (STAFF_ONLY_RPC.has(fnName) && !isForumRpcStaff(user)) {
    const error = new Error('Требуются права модератора');
    error.status = user?.id ? 403 : 401;
    throw error;
  }

  if (AUTHENTICATED_RPC.has(fnName) && !user?.id) {
    const error = new Error('Необходимо войти в систему');
    error.status = 401;
    throw error;
  }

  if (fnName === 'forum_recalculate_authority' && !isForumRpcStaff(user)
      && params.p_user_id !== user?.id) {
    const error = new Error('Нельзя пересчитывать другого пользователя');
    error.status = 403;
    throw error;
  }

  if (fnName === 'forum_purchase_promo') {
    params.p_user_id = user.id;
  }

  if (fnName === 'forum_mark_read') {
    params.p_user_id = user.id;
  }

  if (fnName === 'forum_moderate_promo') {
    params.p_moderator_id = user.id;
  }

  if (fnName === 'delete_forum_topic_cascade' && user?.role !== 'service_role') {
    params.p_moderator_id = user.id;
  }

  return params;
}
