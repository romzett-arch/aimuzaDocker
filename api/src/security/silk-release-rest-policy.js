export const USER_RELEASE_PROTECTED_COLUMNS = new Set([
  'id', 'user_id', 'status', 'admin_note', 'submitted_at', 'reviewed_at',
  'sent_to_silk_at', 'live_at', 'created_at', 'updated_at', 'has_assigned_isrc',
]);

export const ADMIN_RELEASE_DELETE_FILTER = `"status" IN ('draft', 'ready', 'rejected')`;
