/**
 * Authorization policy for Support and QA tables exposed by the custom REST API.
 *
 * The API connects as the database owner and therefore bypasses ordinary RLS.
 * Every read and mutation for these tables must be scoped here explicitly.
 */

const SUPPORT_QA_TABLES = new Set([
  'support_tickets', 'ticket_messages', 'support_ticket_events',
  'qa_tickets', 'qa_comments', 'qa_votes', 'qa_bounties', 'qa_config',
  'qa_tester_stats', 'qa_ticket_events',
  'notifications',
]);

const ADMIN_MANAGED_TABLES = new Set(['qa_bounties', 'qa_config']);
const SERVER_MANAGED_TABLES = new Set([
  'support_ticket_events', 'qa_ticket_events', 'qa_tester_stats', 'qa_votes',
]);

const USER_SUPPORT_INSERT_COLUMNS = new Set(['user_id', 'subject', 'category', 'priority', 'message']);
const USER_SUPPORT_UPDATE_COLUMNS = new Set(['status', 'resolved_at', 'updated_at']);
const USER_MESSAGE_INSERT_COLUMNS = new Set([
  'ticket_id', 'user_id', 'message', 'attachment_url', 'is_staff', 'is_staff_reply',
]);
const USER_QA_INSERT_COLUMNS = new Set([
  'reporter_id', 'title', 'description', 'category', 'severity', 'steps_to_reproduce',
  'expected_behavior', 'actual_behavior', 'page_url', 'user_agent', 'browser_info',
  'screenshots', 'bounty_id', 'tags', 'metadata',
]);
const USER_QA_COMMENT_INSERT_COLUMNS = new Set([
  'ticket_id', 'user_id', 'message', 'attachments', 'is_staff', 'is_system',
]);

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

export function isSupportQaTable(table) {
  return SUPPORT_QA_TABLES.has(table);
}

export function isSupportQaStaff(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return ['moderator', 'admin', 'super_admin', 'superadmin'].includes(role);
}

export function isSupportQaAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return ['admin', 'super_admin', 'superadmin'].includes(role);
}

export function isSupportQaSuperAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'super_admin' || role === 'superadmin' || user?.is_super_admin === true;
}

export function assertSupportQaReadAccess(table, user) {
  if (!isSupportQaTable(table) || table === 'qa_bounties' || table === 'qa_config') return;
  requireAuthenticated(user);
}

export function getSupportQaReadScope(table, user, startIndex = 1) {
  if (!isSupportQaTable(table) || user?.role === 'service_role' || table === 'qa_config') {
    return { sql: '', params: [] };
  }

  if (table === 'notifications') {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }

  if (isSupportQaStaff(user)) return { sql: '', params: [] };

  if (table === 'qa_bounties') {
    return { sql: '"is_active" IS TRUE AND ("expires_at" IS NULL OR "expires_at" > now())', params: [] };
  }

  if (!user?.id) return { sql: 'FALSE', params: [] };

  if (table === 'support_tickets') {
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }
  if (table === 'ticket_messages') {
    return {
      sql: `EXISTS (SELECT 1 FROM public.support_tickets st WHERE st.id = ticket_messages.ticket_id AND st.user_id = $${startIndex})`,
      params: [user.id],
    };
  }
  if (table === 'support_ticket_events') {
    return {
      sql: `EXISTS (SELECT 1 FROM public.support_tickets st WHERE st.id = support_ticket_events.ticket_id AND st.user_id = $${startIndex})`,
      params: [user.id],
    };
  }
  if (table === 'qa_tickets') {
    return { sql: `"reporter_id" = $${startIndex}`, params: [user.id] };
  }
  if (table === 'qa_comments') {
    return {
      sql: `EXISTS (SELECT 1 FROM public.qa_tickets qt WHERE qt.id = qa_comments.ticket_id AND qt.reporter_id = $${startIndex})`,
      params: [user.id],
    };
  }
  if (table === 'qa_ticket_events') {
    return {
      sql: `EXISTS (SELECT 1 FROM public.qa_tickets qt WHERE qt.id = qa_ticket_events.ticket_id AND qt.reporter_id = $${startIndex})`,
      params: [user.id],
    };
  }
  if (table === 'qa_votes' || table === 'qa_tester_stats') {
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }
  return { sql: 'FALSE', params: [] };
}

export function assertSupportQaMutationAccess(table, user, operation) {
  if (!isSupportQaTable(table)) return;
  requireAuthenticated(user);

  if (ADMIN_MANAGED_TABLES.has(table) && !isSupportQaAdmin(user)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }
  if (SERVER_MANAGED_TABLES.has(table) && user.role !== 'service_role') {
    throw httpError(403, 'Direct mutation is not allowed for this resource', 'SERVER_MANAGED_RESOURCE');
  }
  if (operation === 'delete' && ['support_tickets', 'qa_tickets'].includes(table) && !isSupportQaSuperAdmin(user)) {
    throw httpError(403, 'Super administrator access required', 'SUPER_ADMIN_REQUIRED');
  }
  if (operation !== 'insert' && ['ticket_messages', 'qa_comments'].includes(table) && !isSupportQaStaff(user)) {
    throw httpError(403, 'Messages are append-only', 'APPEND_ONLY_RESOURCE');
  }
  if (table === 'qa_tickets' && operation === 'update' && !isSupportQaStaff(user)) {
    throw httpError(403, 'QA ticket updates are staff-only', 'STAFF_REQUIRED');
  }
}

export function applySupportQaInsertOwnership(table, row, user) {
  if (!isSupportQaTable(table) || user?.role === 'service_role') return row;
  if (table === 'support_tickets') return { ...row, user_id: user.id };
  if (table === 'ticket_messages') {
    const staff = isSupportQaStaff(user);
    return { ...row, user_id: user.id, is_staff: staff, is_staff_reply: staff };
  }
  if (table === 'qa_tickets') return { ...row, reporter_id: user.id };
  if (table === 'qa_comments') {
    return { ...row, user_id: user.id, is_staff: isSupportQaStaff(user), is_system: false };
  }
  if (table === 'qa_bounties') return { ...row, created_by: user.id };
  return row;
}

export function filterSupportQaMutationColumns(table, columns, user, operation) {
  if (!isSupportQaTable(table) || isSupportQaStaff(user) || table === 'notifications') return columns;
  let allowed = new Set();
  if (table === 'support_tickets') {
    allowed = operation === 'insert' ? USER_SUPPORT_INSERT_COLUMNS : USER_SUPPORT_UPDATE_COLUMNS;
  } else if (table === 'ticket_messages' && operation === 'insert') {
    allowed = USER_MESSAGE_INSERT_COLUMNS;
  } else if (table === 'qa_tickets' && operation === 'insert') {
    allowed = USER_QA_INSERT_COLUMNS;
  } else if (table === 'qa_comments' && operation === 'insert') {
    allowed = USER_QA_COMMENT_INSERT_COLUMNS;
  }
  return columns.filter(column => allowed.has(column));
}

export function getSupportQaMutationScope(table, user, startIndex = 1) {
  if (!isSupportQaTable(table) || user?.role === 'service_role') return { sql: '', params: [] };
  requireAuthenticated(user);
  if (table === 'notifications') return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  if (isSupportQaStaff(user)) return { sql: '', params: [] };
  if (table === 'support_tickets') return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  if (table === 'qa_tickets') return { sql: `"reporter_id" = $${startIndex}`, params: [user.id] };
  return { sql: 'FALSE', params: [] };
}

export async function assertSupportQaInsertRelation(client, table, row, user) {
  if (isSupportQaStaff(user) || user?.role === 'service_role') return;
  let result;
  if (table === 'ticket_messages') {
    result = await client.query(
      'SELECT 1 FROM public.support_tickets WHERE id = $1 AND user_id = $2 AND status NOT IN (\'resolved\', \'closed\')',
      [row.ticket_id, user.id],
    );
  } else if (table === 'qa_comments') {
    result = await client.query(
      'SELECT 1 FROM public.qa_tickets WHERE id = $1 AND reporter_id = $2 AND status <> \'closed\'',
      [row.ticket_id, user.id],
    );
  } else {
    return;
  }
  if (result.rowCount !== 1) {
    throw httpError(403, 'Cannot add a message to this ticket', 'TICKET_ACCESS_REQUIRED');
  }
}
