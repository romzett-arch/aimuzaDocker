import path from 'node:path';
import { safePath } from '../services/storage-paths.js';
import { isSupportQaStaff } from '../security/support-qa-rest-policy.js';

const SCREENSHOT_TYPES = new Map([
  ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'], ['.jfif', 'image/jpeg'],
  ['.png', 'image/png'], ['.gif', 'image/gif'], ['.webp', 'image/webp'],
]);

function screenshotLocation(filePath) {
  const normalizedPath = path.posix.normalize('/' + filePath).slice(1);
  const [ownerId, folder, ...rest] = normalizedPath.split('/');
  if (!ownerId || folder !== 'bug-reports' || !rest.some(Boolean)) return null;
  return { ownerId, normalizedPath };
}

export function registerQaScreenshotStorage(router) {
  router.get('/object/public/avatars/*', (req, res, next) => {
    if (!screenshotLocation(req.params[0])) return next();
    res.set('Cache-Control', 'private, no-store');
    return res.status(404).json({ error: 'Not found' });
  });

  router.get('/object/avatars/*', (req, res, next) => {
    const screenshot = screenshotLocation(req.params[0]);
    if (!screenshot) return next();

    res.set('Cache-Control', 'private, no-store');
    if (!req.user?.id || req.user.role === 'anon') {
      return res.status(401).json({ error: 'Authentication required' });
    }
    if (req.user.id !== screenshot.ownerId && !isSupportQaStaff(req.user)) {
      return res.status(403).json({ error: 'Access denied' });
    }

    const filename = safePath('avatars', screenshot.normalizedPath);
    if (!filename) return res.status(404).json({ error: 'Not found' });
    const imageType = SCREENSHOT_TYPES.get(path.extname(filename).toLowerCase());
    res.set('X-Content-Type-Options', 'nosniff');
    if (imageType) {
      res.type(imageType);
    } else {
      res.attachment(path.basename(filename)).type('application/octet-stream');
    }
    return res.sendFile(filename, { cacheControl: false, acceptRanges: false }, error => {
      if (!error) return;
      if (res.headersSent) return next(error);
      return res.status(error.status || 500).json({ error: 'Screenshot unavailable' });
    });
  });
}
