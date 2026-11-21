import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { maxAdminList, setMaxBlocked, validMaxId } from '../services/max-admin.js';
import { requestMaxBroadcast } from '../services/max-broadcast.js';

const router = Router();
const broadcastActions = new Set(['broadcast-groups', 'broadcast-add-group', 'broadcast-send', 'broadcast-status']);

router.post('/max-admin', requireAuth, async (req, res, next) => {
  res.set('Cache-Control', 'private, no-store');
  if (req.user.role !== 'authenticated' || !['admin', 'super_admin'].includes(req.user.app_role)) {
    return res.status(403).json({ code: 'ADMIN_REQUIRED' });
  }
  const { action, search = '', filter = 'all', page = 0, maxId, blocked } = req.body ?? {};
  try {
    if (broadcastActions.has(action)) {
      const { id, text, targets, chatId, includeBotLink } = req.body;
      const [status, result] = await requestMaxBroadcast(req.user.id, { action, id, text, targets, chatId, includeBotLink });
      return res.status(status).json(result);
    }
    if (action === 'list' && typeof search === 'string' && search.length <= 100 &&
        ['all', 'linked', 'max_only', 'blocked'].includes(filter) && Number.isSafeInteger(page) && page >= 0 && page < 10000) {
      return res.json(await maxAdminList({ search: search.trim(), filter, offset: page * 25 }));
    }
    if (action === 'block' && validMaxId(maxId) && typeof blocked === 'boolean') {
      const changed = await setMaxBlocked(maxId, blocked, req.user.id);
      if (!changed && blocked) return res.status(404).json({ code: 'NOT_FOUND' });
      return res.json({ ok: true });
    }
    return res.status(400).json({ code: 'BAD_INPUT' });
  } catch (error) { next(error); }
});

export default router;
