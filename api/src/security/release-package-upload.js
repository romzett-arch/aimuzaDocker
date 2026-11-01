import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

export const RELEASE_PACKAGE_UPLOAD_LIMIT = 1024 * 1024 * 1024;

// Mounted at /storage/v1/object. Only internal, raw ZIP uploads qualify.
export function isReleasePackageUpload(req) {
  return req.user?.role === 'service_role'
    && ['POST', 'PUT'].includes(req.method)
    && /^\/tracks\/release-packages\/[0-9a-f-]{36}\/release-package-audio-v3\.zip$/i.test(req.path)
    && String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase() === 'application/zip';
}

export function createReleasePackageUpload(root = process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads') {
  return async (req, res, next) => {
    if (!isReleasePackageUpload(req)) return next();
    const relativePath = req.path.slice(1);
    const destination = path.resolve(root, relativePath);
    const temporary = `${destination}.${crypto.randomUUID()}.part`;
    let received = 0;
    const bound = new Transform({
      transform(chunk, _encoding, callback) {
        received += chunk.length;
        callback(received > RELEASE_PACKAGE_UPLOAD_LIMIT
          ? Object.assign(new Error('File size limit exceeded'), { status: 413 })
          : null, chunk);
      },
    });
    try {
      await fs.promises.mkdir(path.dirname(destination), { recursive: true });
      await pipeline(req, bound, fs.createWriteStream(temporary, { flags: 'wx', mode: 0o640 }));
      if (!received) throw Object.assign(new Error('No file provided'), { status: 400 });
      await fs.promises.rename(temporary, destination);
      res.json({ Key: relativePath, data: { path: relativePath } });
    } catch (error) {
      await fs.promises.unlink(temporary).catch(() => {});
      if (!res.destroyed) next(error);
    }
  };
}
