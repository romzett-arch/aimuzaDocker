import path from 'node:path';

const UPLOADS_DIR = process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads';

// A3: Path traversal protection — ensure path stays inside UPLOADS_DIR
export function safePath(bucket, filePath) {
  if (!/^[a-zA-Z0-9_-]+$/.test(bucket)) return null;
  const bucketRoot=path.resolve(UPLOADS_DIR,bucket);
  const full = path.resolve(bucketRoot,filePath);
  if (!full.startsWith(`${bucketRoot}${path.sep}`)) {
    return null; // traversal attempt
  }
  return full;
}
