/**
 * Maintenance Mode Middleware
 * Blocks write operations (POST/PATCH/DELETE) for non-admin users during maintenance.
 * Caches maintenance status and whitelist to avoid DB queries on every request.
 */
import { pool } from '../db.js';

let maintenanceActive = false;
let whitelistedUserIds = new Set();
let lastCheck = 0;
const CHECK_INTERVAL_MS = 10_000;

async function refreshMaintenanceStatus() {
  const now = Date.now();
  if (now - lastCheck < CHECK_INTERVAL_MS) return;
  lastCheck = now;

  try {
    const { rows } = await pool.query(
      `SELECT COALESCE((SELECT lower(value) = 'true' FROM public.settings WHERE key = 'maintenance_mode'), false) AS active`
    );
    maintenanceActive = rows[0]?.active === true;

    if (maintenanceActive) {
      const wl = await pool.query(`SELECT user_id::text FROM public.maintenance_whitelist`);
      whitelistedUserIds = new Set(wl.rows.map(r => r.user_id));
    }
  } catch (err) {
    console.error('[Maintenance] Status check failed:', err.message);
    // Fail-closed: treat as maintenance active on error
    maintenanceActive = true;
  }
}

function isAdminRole(appRole) {
  return appRole === 'admin' || appRole === 'super_admin';
}

/**
 * Blocks mutating requests (POST/PATCH/DELETE) during maintenance
 * for non-admin, non-whitelisted, non-service-role users.
 *
 * Allows:
 *  - GET/HEAD/OPTIONS (read-only)
 *  - service_role requests (internal)
 *  - admin / super_admin users
 *  - whitelisted users
 *  - /auth/v1/token (login must always work)
 *  - /functions/v1/maintenance-status (status check must always work)
 */
export async function maintenanceGuard(req, res, next) {
  // Read-only methods always pass
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();




  try {
    await refreshMaintenanceStatus();
  } catch (err) {
    console.error('[Maintenance] refreshMaintenanceStatus threw:', err.message);
    maintenanceActive = true;
  }

  if (!maintenanceActive) return next();

  // Always allow login
  if (req.path.startsWith('/auth/v1/token')) return next();

  // Always allow maintenance status check
  if (req.path.includes('/maintenance-status')) return next();

  // Allow password reset flow
  if (req.path.includes('/auth/v1/recover') || req.path.includes('/send-auth-email')) return next();

  // External service callbacks must always pass (Suno, Robokassa, YooKassa, etc.)
  const CALLBACK_PATHS = [
    '/suno-callback', '/suno-cover-callback', '/suno-video-callback',
    '/lyrics-callback', '/wav-callback', '/promo-video-callback',
    '/robokassa-callback', '/yookassa-callback',
  ];
  if (CALLBACK_PATHS.some(p => req.path.includes(p))) return next();

  // Service role (inter-service calls) always allowed
  if (req.user?.role === 'service_role') return next();

  // Admin users pass
  if (req.user && isAdminRole(req.user.app_role)) return next();

  // Whitelisted users pass
  if (req.user && whitelistedUserIds.has(req.user.id)) return next();

  // Allow read-only notifications updates (mark as read)
  if (req.path.includes('/notifications') && req.method === 'PATCH') return next();

  // Block everything else
  console.warn(`[Maintenance] Blocked ${req.method} ${req.path} for user=${req.user?.id || 'anon'} app_role=${req.user?.app_role || 'none'}`);
  return res.status(503).json({
    error: 'Service is under maintenance',
    code: 'MAINTENANCE_MODE',
    message: 'Сервис на техобслуживании. Попробуйте позже.',
  });
}
