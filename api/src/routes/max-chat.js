import { timingSafeEqual } from 'node:crypto';
import { Router } from 'express';
import { registerMaxChatAccount, startMaxAuth, unlinkMaxAccount, verifyMaxAuth } from '../services/max-chat-registration.js';
import { linkedMaxAccount, maxAccount, selectMaxMode } from '../services/max-chat-profiles.js';
import { actions, ChatActionError, uuid } from '../services/max-chat-actions.js';
import { isMaxBlocked, validMaxId } from '../services/max-admin.js';
import { readMaxImageInput } from '../services/max-image-input.js';
import { recordMaxIdentity } from '../services/max-chat-identity.js';

const router = Router();
const secret = Buffer.from(process.env.MAX_INTERNAL_SECRET || '');
router.use((_req,res,next) => { res.set('Cache-Control','no-store'); next(); });

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
    // Мастер привязки/регистрации аккаунта сайта — целиком в личном чате MAX.
    if (action==='authEmail') return res.json(await startMaxAuth(maxId, req.body.email));
    if (action==='authRegister') return res.json(await registerMaxChatAccount(maxId, req.body));
    if (action==='authVerify') return res.json(await verifyMaxAuth(maxId, req.body));
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
