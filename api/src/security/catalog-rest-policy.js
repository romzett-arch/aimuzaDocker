/**
 * Authorization boundary for generator reference data and legal documents.
 *
 * The REST gateway connects as the database owner, so PostgreSQL RLS cannot
 * protect these mutations. Reference data is public to read, but only an
 * administrator may change it. Draft legal documents are admin-only.
 */

const CATALOG_TABLES = new Set([
  'genre_categories',
  'genres',
  'vocal_types',
  'templates',
  'artist_styles',
  'ai_models',
  'legal_documents',
]);

function httpError(status, message, code) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  return error;
}

export function isCatalogAdmin(user) {
  if (user?.role === 'service_role') return true;
  const role = String(user?.app_role || '').toLowerCase();
  return role === 'admin' || role === 'super_admin' || role === 'superadmin';
}

export function isCatalogTable(table) {
  return CATALOG_TABLES.has(table);
}

export function assertCatalogMutationAccess(table, user) {
  if (!isCatalogTable(table)) return;
  if (!user?.id || user.role === 'anon') {
    throw httpError(401, 'Authentication required', 'AUTH_REQUIRED');
  }
  if (!isCatalogAdmin(user)) {
    throw httpError(403, 'Administrator access required', 'ADMIN_REQUIRED');
  }
}

export function getCatalogReadScope(table, user) {
  if (table === 'legal_documents' && !isCatalogAdmin(user)) {
    return { sql: '"is_published" IS TRUE', params: [] };
  }
  return { sql: '', params: [] };
}
