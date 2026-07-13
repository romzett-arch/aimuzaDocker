/**
 * Authorization policy for direct REST mutations of forum tables.
 *
 * The API connects as the database owner, so PostgreSQL RLS cannot be the only
 * protection here. Every direct mutation must be scoped explicitly.
 */

const ADMIN_ONLY_TABLES = new Set([
  'forum_automod_settings',
  'forum_categories',
  'forum_content_quality',
  'forum_content_purchases',
  'forum_hub_config',
  'forum_knowledge_articles',
  'forum_promo_slots',
  'forum_reputation_config',
  'forum_reputation_log',
  'forum_similar_topics',
  'forum_tags',
  'forum_topic_clusters',
  'forum_topic_cluster_members',
  'forum_topic_boosts',
]);

const STAFF_MANAGED_TABLES = new Set([
  'forum_mod_logs',
  'forum_staff_notes',
  'forum_user_bans',
  'forum_warning_points',
  'forum_warnings',
]);

const STAFF_GLOBAL_SCOPE_TABLES = new Set([
  ...STAFF_MANAGED_TABLES,
  'forum_posts',
  'forum_reports',
  'forum_topics',
  'forum_user_stats',
]);

const STAFF_UPDATE_COLUMNS = new Map([
  ['forum_posts', new Set(['is_hidden', 'hidden_by', 'hidden_at', 'hidden_reason'])],
  ['forum_topics', new Set(['is_hidden', 'is_locked', 'is_pinned', 'category_id'])],
  ['forum_reports', new Set(['status', 'moderator_id', 'resolution', 'resolved_at', 'auto_actioned'])],
  ['forum_warnings', new Set(['is_active', 'acknowledged_at', 'expires_at'])],
  ['forum_user_bans', new Set(['is_active', 'expires_at', 'cooldown_until'])],
  ['forum_warning_points', new Set(['points', 'total_points', 'last_decay_at', 'updated_at'])],
  ['forum_user_stats', new Set(['warnings_count', 'trust_level', 'updated_at'])],
]);

const OWNER_COLUMNS = new Map([
  ['forum_activity_log', 'user_id'],
  ['forum_attachments', 'user_id'],
  ['forum_bookmarks', 'user_id'],
  ['forum_category_subscriptions', 'user_id'],
  ['forum_citations', 'cited_by'],
  ['forum_content_purchases', 'buyer_id'],
  ['forum_drafts', 'user_id'],
  ['forum_poll_votes', 'user_id'],
  ['forum_post_reactions', 'user_id'],
  ['forum_post_votes', 'user_id'],
  ['forum_posts', 'user_id'],
  ['forum_premium_content', 'author_id'],
  ['forum_promo_slots', 'user_id'],
  ['forum_read_status', 'user_id'],
  ['forum_reports', 'reporter_id'],
  ['forum_topic_boosts', 'boosted_by'],
  ['forum_topic_subscriptions', 'user_id'],
  ['forum_topics', 'user_id'],
  ['forum_user_ignores', 'user_id'],
  ['forum_user_reads', 'user_id'],
  ['forum_warning_appeals', 'user_id'],
  ['forum_user_stats', 'user_id'],
]);

const RELATION_SCOPES = new Map([
  ['forum_polls', 'EXISTS (SELECT 1 FROM forum_topics ft WHERE ft.id = forum_polls.topic_id AND ft.user_id = $USER)'],
  ['forum_poll_options', 'EXISTS (SELECT 1 FROM forum_polls fp JOIN forum_topics ft ON ft.id = fp.topic_id WHERE fp.id = forum_poll_options.poll_id AND ft.user_id = $USER)'],
  ['forum_topic_tags', 'EXISTS (SELECT 1 FROM forum_topics ft WHERE ft.id = forum_topic_tags.topic_id AND ft.user_id = $USER)'],
  ['forum_premium_content', 'EXISTS (SELECT 1 FROM forum_topics ft WHERE ft.id = forum_premium_content.topic_id AND ft.user_id = $USER)'],
]);

const READ_ONLY_TABLES = new Set(['forum_link_previews']);

const PRIVATE_READ_OWNER_COLUMNS = new Map([
  ['forum_bookmarks', 'user_id'],
  ['forum_category_subscriptions', 'user_id'],
  ['forum_content_purchases', 'buyer_id'],
  ['forum_drafts', 'user_id'],
  ['forum_read_status', 'user_id'],
  ['forum_reports', 'reporter_id'],
  ['forum_topic_subscriptions', 'user_id'],
  ['forum_user_ignores', 'user_id'],
  ['forum_user_reads', 'user_id'],
  ['forum_warning_appeals', 'user_id'],
]);

const PUBLIC_USER_STATS_COLUMNS = [
  'id', 'user_id', 'topics_count', 'posts_count', 'likes_received', 'likes_given',
  'reputation', 'solutions_count', 'trust_level', 'joined_at', 'last_post_at', 'updated_at',
  'xp_total', 'xp_forum', 'xp_music', 'xp_social', 'featured_badges',
  'hide_forum_activity', 'hide_online_status', 'tier', 'tier_progress', 'vote_weight',
  'curator_score', 'quality_ratio', 'tracks_published', 'tracks_liked_received',
  'guides_published', 'collaborations_count', 'total_play_time_seconds', 'streak_days',
  'best_streak', 'last_activity_date', 'authority_score', 'authority_tier',
  'content_quality_avg', 'citations_received', 'mentorship_score', 'expertise_tags',
  'can_create_articles', 'can_boost_topics', 'authority_updated_at', 'last_active_at',
  'posts_created', 'topics_created', 'reputation_score',
];

export function isForumTable(table) {
  return typeof table === 'string' && table.startsWith('forum_');
}

export function isForumAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function isForumStaff(user) {
  if (isForumAdmin(user)) return true;
  return String(user?.app_role || '').toLowerCase() === 'moderator';
}

export function assertForumMutationAccess(table, user) {
  if (!isForumTable(table)) return;
  if (!user?.id || user.role === 'anon') {
    const error = new Error('Authentication required for forum mutations');
    error.status = 401;
    throw error;
  }
  if ((ADMIN_ONLY_TABLES.has(table) || READ_ONLY_TABLES.has(table)) && !isForumAdmin(user)) {
    const error = new Error('Administrator permission required');
    error.status = 403;
    throw error;
  }
  if (STAFF_MANAGED_TABLES.has(table) && !isForumStaff(user)) {
    const error = new Error('Moderator permission required');
    error.status = 403;
    throw error;
  }
  if (!ADMIN_ONLY_TABLES.has(table) && !READ_ONLY_TABLES.has(table)
      && !STAFF_MANAGED_TABLES.has(table) && !OWNER_COLUMNS.has(table) && !RELATION_SCOPES.has(table)) {
    const error = new Error('Direct mutations are not allowed for this forum resource');
    error.status = 403;
    throw error;
  }
}

/** Force ownership on INSERT instead of trusting a client-supplied user id. */
export function applyForumInsertOwnership(table, row, user) {
  if (!isForumTable(table) || isForumAdmin(user)) return row;
  if (isForumStaff(user)) {
    if (table === 'forum_mod_logs') return { ...row, moderator_id: user.id };
    if (table === 'forum_staff_notes') return { ...row, author_id: user.id };
    if (table === 'forum_warnings') return { ...row, issued_by: user.id, moderator_id: user.id };
    if (table === 'forum_user_bans') return { ...row, banned_by: user.id };
    if (table === 'forum_warning_points') return { ...row, issued_by: user.id };
  }
  const ownerColumn = OWNER_COLUMNS.get(table);
  return ownerColumn ? { ...row, [ownerColumn]: user.id } : row;
}

/** Verify ownership for child records which do not carry a user id. */
export async function assertForumInsertRelation(client, table, row, user) {
  if (!isForumTable(table) || isForumAdmin(user) || !RELATION_SCOPES.has(table)) return;

  let query;
  let value;
  if (table === 'forum_polls') {
    query = 'SELECT 1 FROM forum_topics WHERE id = $1 AND user_id = $2';
    value = row.topic_id;
  } else if (table === 'forum_poll_options') {
    query = `SELECT 1 FROM forum_polls fp
             JOIN forum_topics ft ON ft.id = fp.topic_id
             WHERE fp.id = $1 AND ft.user_id = $2`;
    value = row.poll_id;
  } else if (table === 'forum_topic_tags') {
    query = 'SELECT 1 FROM forum_topics WHERE id = $1 AND user_id = $2';
    value = row.topic_id;
  } else if (table === 'forum_premium_content') {
    query = 'SELECT 1 FROM forum_topics WHERE id = $1 AND user_id = $2';
    value = row.topic_id;
  }

  if (!value || !query || (await client.query(query, [value, user.id])).rowCount === 0) {
    const error = new Error('Cannot modify a forum resource owned by another user');
    error.status = 403;
    throw error;
  }
}

/** SQL predicate used by PATCH/DELETE to prevent cross-user mutations. */
export function getForumMutationScope(table, user, parameterNumber) {
  if (!isForumTable(table) || isForumAdmin(user)) return { sql: '', params: [] };
  if (isForumStaff(user) && STAFF_GLOBAL_SCOPE_TABLES.has(table)) return { sql: '', params: [] };
  const ownerColumn = OWNER_COLUMNS.get(table);
  if (ownerColumn) {
    return { sql: `"${ownerColumn}" = $${parameterNumber}`, params: [user.id] };
  }
  const relationScope = RELATION_SCOPES.get(table);
  if (relationScope) {
    return { sql: relationScope.replace('$USER', `$${parameterNumber}`), params: [user.id] };
  }
  return { sql: 'FALSE', params: [] };
}

/** Mandatory visibility predicate for REST reads performed as DB owner. */
export function getForumReadScope(table, user, parameterNumber) {
  if (!isForumTable(table) || isForumAdmin(user)) return { sql: '', params: [] };

  if (isForumStaff(user) && (
    STAFF_GLOBAL_SCOPE_TABLES.has(table)
    || table === 'forum_automod_settings'
    || table === 'forum_warning_appeals'
  )) return { sql: '', params: [] };

  if (table === 'forum_mod_logs' || table === 'forum_staff_notes'
      || table === 'forum_automod_settings' || table === 'forum_hub_config') {
    return { sql: 'FALSE', params: [] };
  }
  if (table === 'forum_warnings' || table === 'forum_user_bans' || table === 'forum_warning_points') {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return { sql: '"user_id" = $' + parameterNumber, params: [user.id] };
  }

  const ownerColumn = PRIVATE_READ_OWNER_COLUMNS.get(table);
  if (ownerColumn) {
    if (!user?.id) return { sql: 'FALSE', params: [] };
    return { sql: `"${ownerColumn}" = $${parameterNumber}`, params: [user.id] };
  }
  if (table === 'forum_knowledge_articles') {
    return { sql: 'status = \'published\'', params: [] };
  }
  if (table === 'forum_topics' || table === 'forum_posts') {
    return { sql: 'is_hidden = FALSE', params: [] };
  }
  return { sql: '', params: [] };
}

/** Replace SELECT * for public forum stats with a non-sensitive projection. */
export function getForumReadColumns(table, user, columns) {
  if (table !== 'forum_user_stats' || isForumStaff(user)) return columns;
  const safe = new Set(PUBLIC_USER_STATS_COLUMNS);
  if (columns === '*') return PUBLIC_USER_STATS_COLUMNS.map(column => `"${column}"`).join(', ');

  const requested = String(columns).split(',').map(column => column.trim().replace(/^"|"$/g, ''));
  const allowed = requested.filter(column => safe.has(column));
  if (allowed.length === 0) return '"id", "user_id"';
  return allowed.map(column => `"${column}"`).join(', ');
}

export const FORUM_IMMUTABLE_USER_COLUMNS = new Set([
  'user_id', 'author_id', 'buyer_id', 'boosted_by', 'cited_by', 'reporter_id',
  'moderator_id', 'curator_id', 'banned_by', 'issued_by',
  'is_pinned', 'is_locked', 'is_hidden', 'is_solution', 'is_active',
  'status', 'resolution', 'resolved_at', 'hidden_by', 'hidden_at', 'hidden_reason',
  'views_count', 'posts_count', 'topics_count', 'votes_count', 'total_votes',
  'quality_score', 'authority_score', 'reputation_score',
]);

export const FORUM_PROTECTED_INSERT_COLUMNS = new Set([
  'moderator_id', 'curator_id', 'banned_by', 'issued_by',
  'is_pinned', 'is_locked', 'is_hidden', 'is_solution', 'is_active',
  'status', 'resolution', 'resolved_at', 'hidden_by', 'hidden_at', 'hidden_reason',
  'views_count', 'posts_count', 'topics_count', 'votes_count', 'total_votes',
  'likes_count', 'purchases_count', 'revenue_total', 'quality_score',
  'authority_score', 'reputation_score',
]);

export function filterForumStaffUpdateColumns(table, columns, user) {
  if (!isForumTable(table) || isForumAdmin(user) || !isForumStaff(user)) return columns;
  const allowed = STAFF_UPDATE_COLUMNS.get(table);
  return allowed ? columns.filter(column => allowed.has(column)) : columns;
}
