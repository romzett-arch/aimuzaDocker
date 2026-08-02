/**
 * Authorization boundary for identities, roles, verification and sanctions.
 *
 * The REST gateway connects as the database owner and therefore bypasses RLS.
 * Every table in this domain must be explicitly scoped here. Administrative
 * state transitions are RPC-only so that they remain transactional and audited.
 */

const USER_ACCESS_TABLES = new Set([
  'user_roles',
  'role_invitations',
  'role_invitation_permissions',
  'moderator_permissions',
  'permission_categories',
  'moderator_presets',
  'role_change_logs',
  'verification_requests',
  'user_blocks',
]);

const RPC_ONLY_MUTATION_TABLES = new Set([
  'user_roles',
  'role_invitations',
  'role_invitation_permissions',
  'moderator_permissions',
  'verification_requests',
  'user_blocks',
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

export function isUsersAccessTable(table) {
  return USER_ACCESS_TABLES.has(table);
}

export function isUsersAccessAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

function requireAuthentication(user) {
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
}

/** Mandatory visibility predicate for reads executed as database owner. */
export function getUsersAccessReadScope(table, user, parameterNumber) {
  if (!isUsersAccessTable(table)) return { sql: '', params: [] };

  if (table === 'permission_categories' || table === 'moderator_presets') {
    if (isUsersAccessAdmin(user)) return { sql: '', params: [] };
    return { sql: '"is_active" IS TRUE', params: [] };
  }

  requireAuthentication(user);
  if (isUsersAccessAdmin(user)) return { sql: '', params: [] };

  if (table === 'user_roles') {
    // Roles are used by authenticated community screens for role badges.
    return { sql: '', params: [] };
  }
  if (table === 'role_invitations' || table === 'verification_requests'
      || table === 'moderator_permissions') {
    return { sql: `"user_id" = $${parameterNumber}`, params: [user.id] };
  }
  if (table === 'role_invitation_permissions') {
    return {
      sql: `EXISTS (SELECT 1 FROM role_invitations ri WHERE ri.id = role_invitation_permissions.invitation_id AND ri.user_id = $${parameterNumber})`,
      params: [user.id],
    };
  }

  // Sanction history and the administrative audit log are admin-only.
  throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
}

export function assertUsersAccessMutation(table, user, operation) {
  if (!isUsersAccessTable(table) && table !== 'profiles') return;
  requireAuthentication(user);
  if (user.role === 'service_role') return;

  if (table === 'profiles') {
    if (operation === 'insert' || operation === 'update') return;
    throw httpError(403, 'Profile deletion must use the audited account command', 'RPC_REQUIRED');
  }

  if (RPC_ONLY_MUTATION_TABLES.has(table)) {
    throw httpError(403, 'Direct mutation is disabled; use the authorized RPC', 'RPC_REQUIRED');
  }

  if (!isUsersAccessAdmin(user)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }

  if (table === 'role_change_logs' && operation !== 'insert') {
    throw httpError(403, 'Audit records are append-only', 'AUDIT_APPEND_ONLY');
  }
}

export function applyUsersAccessInsertOwnership(table, row, user) {
  if (table !== 'profiles' || isUsersAccessAdmin(user)) return row;
  return { ...row, user_id: user.id };
}

export function getUsersAccessMutationScope(table, user, parameterNumber) {
  if (table !== 'profiles' || isUsersAccessAdmin(user)) return { sql: '', params: [] };
  return { sql: `"user_id" = $${parameterNumber}`, params: [user.id] };
}
