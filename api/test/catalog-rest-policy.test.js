import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertCatalogMutationAccess,
  getCatalogReadScope,
  isCatalogTable,
} from '../src/security/catalog-rest-policy.js';

const user = { id: 'user-1', role: 'authenticated', app_role: 'user' };
const admin = { id: 'admin-1', role: 'authenticated', app_role: 'admin' };
const superAdmin = { id: 'admin-2', role: 'authenticated', app_role: 'super_admin' };
const service = { id: 'service-role', role: 'service_role' };

test('catalog tables form an explicit protected mutation domain', () => {
  for (const table of [
    'genre_categories', 'genres', 'vocal_types', 'templates',
    'artist_styles', 'ai_models', 'legal_documents',
  ]) {
    assert.equal(isCatalogTable(table), true);
  }
  assert.equal(isCatalogTable('tracks'), false);
});

test('catalog mutations require an administrator', () => {
  for (const table of ['genres', 'templates', 'ai_models', 'legal_documents']) {
    assert.throws(() => assertCatalogMutationAccess(table, null), error => error.status === 401);
    assert.throws(() => assertCatalogMutationAccess(table, user), error => error.status === 403);
    assert.doesNotThrow(() => assertCatalogMutationAccess(table, admin));
    assert.doesNotThrow(() => assertCatalogMutationAccess(table, superAdmin));
    assert.doesNotThrow(() => assertCatalogMutationAccess(table, service));
  }
});

test('public legal-document reads only expose published rows', () => {
  assert.equal(getCatalogReadScope('legal_documents', null).sql, '"is_published" IS TRUE');
  assert.equal(getCatalogReadScope('legal_documents', user).sql, '"is_published" IS TRUE');
  assert.equal(getCatalogReadScope('legal_documents', admin).sql, '');
  assert.equal(getCatalogReadScope('legal_documents', superAdmin).sql, '');
  assert.equal(getCatalogReadScope('templates', null).sql, '');
});
