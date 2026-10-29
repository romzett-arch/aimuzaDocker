import path from 'node:path';
import fs from 'node:fs/promises';

export const DAY = 86400000;
const BUCKETS = new Set(['tracks', 'covers', 'audio-references']);

// Normalize identities independently of public/internal hostname, but never trust foreign hosts.
export function mediaKey(value, baseUrl = process.env.BASE_URL || 'http://localhost') {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value, baseUrl);
    const origins = new Set([new URL(baseUrl).origin, 'https://aimuza.ru', 'https://www.aimuza.ru', 'https://app.aimuza.ru', 'http://api:3000', 'http://ffmpeg-api:3001']);
    if (!origins.has(url.origin)) return null;
    let name = decodeURIComponent(url.pathname);
    if (name.includes('\\') || name.includes('\0') || name.split('/').some(p => p === '..' || p === '.')) return null;
    const storage = name.match(/^\/storage\/v1\/object\/(?:public\/)?([^/]+)\/(.+)$/);
    if (storage && BUCKETS.has(storage[1])) return `${storage[1]}/${storage[2]}`;
    const output = name.match(/^(?:\/api\/ffmpeg)?\/output\/([a-zA-Z0-9_.-]+)$/);
    if (output && !output[1].startsWith('.')) return `ffmpeg/${output[1]}`;
  } catch { /* Not a canonical local media URL. */ }
  return null;
}

export function collectKeys(value, keys = new Set(), baseUrl) {
  if (typeof value === 'string') {
    const key = mediaKey(value, baseUrl);
    if (key) keys.add(key);
    // Legacy result_url sometimes contains JSON instead of a URL.
    if (value.startsWith('{') || value.startsWith('[')) {
      try { collectKeys(JSON.parse(value), keys, baseUrl); } catch { /* Plain text. */ }
    }
  } else if (value && typeof value === 'object') {
    for (const item of Object.values(value)) collectKeys(item, keys, baseUrl);
    if (BUCKETS.has(value.storage_bucket) && typeof value.storage_path === 'string') keys.add(`${value.storage_bucket}/${value.storage_path}`);
  }
  return keys;
}

export async function safeFile(root, relative) {
  if (!relative || relative.includes('\\') || relative.includes('\0') || relative.split('/').some(p => !p || p === '.' || p === '..')) throw new Error('Invalid media path');
  const base = await fs.realpath(root);
  const target = path.resolve(base, relative);
  if (!target.startsWith(base + path.sep)) throw new Error('Media path escapes root');
  // Every component must be a real directory/file, never follow a symlink.
  let cursor = base;
  for (const part of relative.split('/')) {
    cursor = path.join(cursor, part);
    try { if ((await fs.lstat(cursor)).isSymbolicLink()) throw new Error('Media symlink rejected'); }
    catch (error) { if (error.code === 'ENOENT') return target; throw error; }
  }
  return target;
}

export async function unlinkMedia(key, roots) {
  const slash = key.indexOf('/');
  const bucket = key.slice(0, slash), relative = key.slice(slash + 1);
  if (bucket !== 'ffmpeg' && !BUCKETS.has(bucket)) throw new Error('Bucket cannot be cleaned');
  const file = await safeFile(bucket === 'ffmpeg' ? roots.ffmpeg : roots.uploads, bucket === 'ffmpeg' ? relative : key);
  let removed = false;
  try { await fs.unlink(file); removed = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (bucket === 'ffmpeg') {
    const sidecar = await safeFile(roots.ffmpeg, `.source_${relative}.json`);
    try { await fs.unlink(sidecar); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return removed;
}

export async function* walkFiles(root, prefix = '') {
  let entries;
  try { entries = await fs.readdir(path.join(root, prefix), { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  for (const entry of entries) {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) yield* walkFiles(root, relative);
    else if (entry.isFile()) {
      const filename = await safeFile(root, relative);
      yield { relative, filename, stat: await fs.stat(filename) };
    }
  }
}
