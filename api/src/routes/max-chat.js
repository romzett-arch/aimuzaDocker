import { timingSafeEqual } from 'node:crypto';
import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { issueMaxLink, prepareMaxConfirmation, confirmMaxAccount, unlinkMaxAccount } from '../services/max-chat-accounts.js';
import { linkedMaxAccount, maxAccount, selectMaxMode, standaloneMaxAccount } from '../services/max-chat-profiles.js';
import { actions, ChatActionError, uuid } from '../services/max-chat-actions.js';
import { isMaxBlocked, validMaxId } from '../services/max-admin.js';
import { readMaxImageInput } from '../services/max-image-input.js';
import { recordMaxIdentity } from '../services/max-chat-identity.js';

const router = Router();
const secret = Buffer.from(process.env.MAX_INTERNAL_SECRET || '');
router.use((_req,res,next) => { res.set('Cache-Control','no-store'); next(); });

router.post('/confirm',requireAuth,async (req,res,next)=>{
  try {
    if (secret.length < 32) return res.sendStatus(503);
    const link = req.body?.link;
    if (req.user.role !== 'authenticated' || typeof link !== 'string' || !/^[a-f0-9]{64}$/.test(link))
      return res.status(400).json({code:'INVALID_LINK'});
    const code = await prepareMaxConfirmation(link,req.user);
    if (!code) return res.status(410).json({code:'INVALID_LINK'});
    res.json({code});
  } catch(error) { next(error); }
});

function requireBot(req, res, next) {
  const candidate = Buffer.from(req.get('x-aimuza-max-secret') || '');
  if (secret.length < 32 || candidate.length !== secret.length || !timingSafeEqual(candidate,secret)) return res.sendStatus(403);
  next();
}

router.post('/internal/:action', requireBot, readMaxImageInput, async(req,res,next)=>{
  const {maxId,ownerId,standalone} = req.body ?? {};
  if (!validMaxId(maxId)) return res.status(400).json({code:'BAD_INPUT'});
  try {
    const action = req.params.action;
    if (action==='identity') {
      const updated = await recordMaxIdentity(maxId, req.body.identity);
      return updated === null ? res.status(400).json({code:'BAD_INPUT'}) : res.json({updated});
    }
    if (await isMaxBlocked(maxId)) return res.status(403).json({code:'MAX_BLOCKED'});
    if (action==='link') {
      const profile = await standaloneMaxAccount(maxId);
      return res.json(await issueMaxLink(maxId, Boolean(profile && !profile.email)));
    }
    if (action==='verify') {
      if (typeof req.body.code !== 'string' || !/^[0-9]{8}$/.test(req.body.code)) return res.status(400).json({code:'BAD_INPUT'});
      return res.json({linked:await confirmMaxAccount(maxId,req.body.code)});
    }
    if (action==='unlink') {
      await unlinkMaxAccount(maxId);
      return res.json({ok:true});
    }
    if (action==='switch') {
      const { mode } = req.body;
      if (mode !== 'max' && mode !== 'site') return res.status(400).json({code:'BAD_INPUT'});
      if (!(await selectMaxMode(maxId, mode))) return res.status(401).json({code:'LINK_REQUIRED'});
      return res.json({mode});
    }
    if (!Object.hasOwn(actions,action)) return res.sendStatus(404);
    if (ownerId !== undefined && !uuid(ownerId)) return res.status(400).json({code:'BAD_INPUT'});
    if (action !== 'profile' && !ownerId) return res.status(400).json({code:'BAD_INPUT'});
    const standaloneEnabled = standalone === true;
    const account = standaloneEnabled ? await maxAccount(maxId, ownerId) : await linkedMaxAccount(maxId, ownerId);
    if (!account) return res.status(401).json({code:standaloneEnabled ? 'PROFILE_CHANGED' : 'LINK_REQUIRED'});
    const result = await actions[action](account,req.body,res);
    if (action!=='media') res.json(result);
  } catch(error) {
    if (error instanceof ChatActionError && !res.headersSent) return res.status(error.status).json({code:error.message});
    next(error);
  }
});
export default router;
