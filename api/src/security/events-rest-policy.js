/** Authorization policy for contests and platform announcements. */

const EVENT_TABLES = new Set([
  'admin_announcements', 'announcement_dismissals', 'contests',
  'contest_entries', 'contest_votes', 'contest_winners', 'contest_jury',
  'contest_jury_scores', 'contest_seasons', 'contest_leagues',
  'contest_achievements', 'contest_user_achievements', 'contest_ratings',
  'contest_asset_downloads', 'contest_entry_comments', 'contest_comment_likes',
]);

const ADMIN_MUTATION_TABLES = new Set([
  'admin_announcements', 'contests', 'contest_winners', 'contest_jury',
  'contest_seasons', 'contest_leagues', 'contest_achievements',
  'contest_user_achievements', 'contest_ratings',
]);

const OWNERSHIP_COLUMNS = new Map([
  ['announcement_dismissals', 'user_id'],
  ['contest_votes', 'user_id'],
  ['contest_asset_downloads', 'user_id'],
  ['contest_entry_comments', 'user_id'],
  ['contest_comment_likes', 'user_id'],
  ['contest_jury_scores', 'jury_user_id'],
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

export function isEventsTable(table) {
  return EVENT_TABLES.has(table);
}

export function isEventsAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function assertEventsMutationAccess(table, user) {
  if (!isEventsTable(table)) return;
  requireAuthenticated(user);

  if (table === 'contest_entries' && !isEventsAdmin(user)) {
    throw httpError(403, 'Contest entries must be submitted through RPC', 'CONTEST_RPC_REQUIRED');
  }
  if (ADMIN_MUTATION_TABLES.has(table) && !isEventsAdmin(user)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }
}

export function applyEventsInsertOwnership(table, row, user) {
  const column = OWNERSHIP_COLUMNS.get(table);
  if (!column || isEventsAdmin(user)) return row;
  return { ...row, [column]: user.id };
}

export function getEventsMutationScope(table, user, startIndex = 1) {
  if (!isEventsTable(table) || isEventsAdmin(user)) return { sql: '', params: [] };
  requireAuthenticated(user);
  const column = OWNERSHIP_COLUMNS.get(table);
  return column
    ? { sql: `"${column}" = $${startIndex}`, params: [user.id] }
    : { sql: 'FALSE', params: [] };
}

export function getEventsReadScope(table, user, startIndex = 1) {
  if (!isEventsTable(table) || isEventsAdmin(user)) return { sql: '', params: [] };

  if (table === 'admin_announcements') {
    return {
      sql: 'is_published IS TRUE AND (publish_at IS NULL OR publish_at <= now()) AND (expires_at IS NULL OR expires_at >= now())',
      params: [],
    };
  }
  if (table === 'contests') {
    return { sql: `status IN ('active', 'voting', 'completed')`, params: [] };
  }
  if (table === 'announcement_dismissals') {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return { sql: `"user_id" = $${startIndex}`, params: [user.id] };
  }
  return { sql: '', params: [] };
}

export async function assertEventsInsertRelation(client, table, row, user) {
  if (table !== 'contest_jury_scores' || isEventsAdmin(user)) return;
  const result = await client.query(
    `SELECT 1 FROM public.contest_jury WHERE contest_id = $1 AND user_id = $2`,
    [row.contest_id, user.id],
  );
  if (result.rowCount !== 1) {
    throw httpError(403, 'Only an assigned jury member may score this contest', 'JURY_REQUIRED');
  }
}
