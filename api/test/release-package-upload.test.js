import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import express from 'express';
import { createUploadBudget } from '../src/security/upload-budget.js';
import { createReleasePackageUpload, isReleasePackageUpload } from '../src/security/release-package-upload.js';

const filePath = '/tracks/release-packages/11111111-1111-4111-8111-111111111111/release-package-audio-v3.zip';

test('larger upload allowance is restricted to internal raw release ZIPs', () => {
 const request = { method: 'POST', path: filePath, user: { role: 'service_role' }, headers: { 'content-type': 'application/zip' } };
 assert(isReleasePackageUpload(request));
 for (const change of [
  { user: { role: 'authenticated', app_role: 'admin' } },
  { path: '/tracks/other.zip' }, { path: filePath.replace('11111111-', '../') },
  { headers: { 'content-type': 'multipart/form-data' } }, { method: 'GET' },
 ]) assert(!isReleasePackageUpload({ ...request, ...change }));
});

test('internal ZIP above 100 MiB streams atomically; failed uploads preserve the previous file', async (t) => {
 const root = await fs.mkdtemp(path.join(os.tmpdir(), 'release-upload-'));
 const app = express();
 app.use((req, _res, next) => { req.user = { id: 'internal', role: 'service_role' }; next(); });
 app.use(createUploadBudget(), createReleasePackageUpload(root));
 app.use((_req, res) => res.sendStatus(404));
 app.use((error, _req, res, _next) => res.status(error.status || 500).json({ error: error.message }));
 const server = app.listen(0, '127.0.0.1');
 await new Promise(resolve => server.once('listening', resolve));
 t.after(async () => { await new Promise(resolve => server.close(resolve)); await fs.rm(root, { recursive: true, force: true }); });
 const url = `http://127.0.0.1:${server.address().port}${filePath}`;
 const chunk = Buffer.alloc(1024 * 1024, 42);
 const response = await fetch(url, {
  method: 'POST', headers: { 'content-type': 'application/zip' }, duplex: 'half',
  body: (async function* () { for (let i = 0; i < 101; i++) yield chunk; })(),
 });
 assert.equal(response.status, 200);
 assert.equal((await response.json()).Key, filePath.slice(1));
 const destination = path.join(root, filePath.slice(1));
 assert.equal((await fs.stat(destination)).size, 101 * chunk.length);
 const empty = await fetch(url, { method: 'PUT', headers: { 'content-type': 'application/zip' }, body: new Uint8Array() });
 assert.equal(empty.status, 400);
 assert.equal((await fs.stat(destination)).size, 101 * chunk.length);
 assert.deepEqual(await fs.readdir(path.dirname(destination)), ['release-package-audio-v3.zip']);
});
