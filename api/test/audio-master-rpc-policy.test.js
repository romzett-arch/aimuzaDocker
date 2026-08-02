import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const rpcRoute = readFileSync(new URL('../src/routes/rpc.js', import.meta.url), 'utf8');

test('audio master queue transaction boundaries require service role', () => {
  const serviceOnlyBlock = rpcRoute.match(/const SERVICE_ROLE_ONLY_RPC = new Set\(\[([\s\S]*?)\]\);/)?.[1] || '';
  assert.match(serviceOnlyBlock, /'claim_track_audio_ingest'/);
  assert.match(serviceOnlyBlock, /'enqueue_audio_master_job'/);
  assert.match(serviceOnlyBlock, /'claim_audio_master_jobs'/);
  assert.match(rpcRoute, /req\.user\?\.role !== 'service_role'/);
});
