import { pool } from '../db.js';

const SAFE_RPC_FOR_BLOCKED_USERS = new Set([
  'get_my_sanction_status',
  'get_user_block_info',
  'is_user_blocked',
]);

function isSafeMethod(method) {
  return method === 'GET' || method === 'HEAD' || method === 'OPTIONS';
}

function getRpcName(path) {
  const match = path.match(/^\/rest\/v1\/rpc\/([^/?#]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

function isAllowedWhileBlocked(req) {
  if (isSafeMethod(req.method)) return true;
  if (req.path === '/health') return true;
  if (req.path.startsWith('/auth/v1/')) return true;

  const rpcName = getRpcName(req.path);
  if (rpcName && SAFE_RPC_FOR_BLOCKED_USERS.has(rpcName)) return true;

  return false;
}

async function getActiveBlock(userId) {
  const result = await pool.query(
    `SELECT id, reason, blocked_at, expires_at
     FROM public.user_blocks
     WHERE user_id = $1
       AND is_active = true
       AND (expires_at IS NULL OR expires_at > now())
     ORDER BY blocked_at DESC
     LIMIT 1`,
    [userId]
  );

  return result.rows[0] || null;
}

export async function blockedUserGuard(req, res, next) {
  if (!req.user || !req.user.id || req.user.id === 'service-role') {
    return next();
  }

  try {
    const activeBlock = await getActiveBlock(req.user.id);
    if (!activeBlock) return next();

    req.user.blocked = true;
    req.user.block = activeBlock;

    if (isAllowedWhileBlocked(req)) return next();

    return res.status(403).json({
      error: 'USER_BLOCKED',
      code: 'USER_BLOCKED',
      message: 'Аккаунт заблокирован',
      block: {
        id: activeBlock.id,
        reason: activeBlock.reason,
        blocked_at: activeBlock.blocked_at,
        expires_at: activeBlock.expires_at,
      },
    });
  } catch (err) {
    console.error('[BlockedUserGuard]', err.message);
    return res.status(500).json({
      error: 'Sanctions check failed',
      code: 'SANCTIONS_CHECK_FAILED',
    });
  }
}
