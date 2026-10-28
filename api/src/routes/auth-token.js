import bcrypt from 'bcryptjs';
import { pool } from '../db.js';
import { signToken, requireAuth } from '../middleware/auth.js';
import { issueRefresh, consumeRefresh, freshRoles } from '../security/refresh-session.js';

const DUMMY_HASH = '$2a$12$K4p9MxVPgOSR5QjKWnJL.OBkqiLbqMy0aZXGxVUP3IxtTGd1bEX6q';

export function registerToken(router) {
  router.post('/token', async (req, res) => {
    try {
      const grantType = req.query.grant_type || req.body.grant_type;

      if (grantType === 'password') {
        const { email, password } = req.body;
        if (!email || !password) {
          return res.status(400).json({ error: 'Email and password required' });
        }

        const result = await pool.query(
          'SELECT id, email, encrypted_password, email_confirmed_at, created_at, is_super_admin, raw_user_meta_data FROM auth.users WHERE email = $1',
          [email.toLowerCase()]
        );

        if (result.rows.length === 0) {
          await bcrypt.compare(password, DUMMY_HASH);
          return res.status(400).json({ error: 'Invalid login credentials', code: 'INVALID_CREDENTIALS' });
        }

        const user = result.rows[0];
        const valid = await bcrypt.compare(password, user.encrypted_password);
        if (!valid) {
          return res.status(400).json({ error: 'Invalid login credentials', code: 'INVALID_CREDENTIALS' });
        }

        if (!user.email_confirmed_at) {
          return res.status(400).json({
            error: 'Email not confirmed',
            code: 'EMAIL_NOT_CONFIRMED',
            message: 'Подтвердите email перед входом. Проверьте почту.',
          });
        }

        const profileRes = await pool.query(
          'SELECT role, is_super_admin, display_name FROM public.profiles WHERE user_id = $1',
          [user.id]
        );
        const profile = profileRes.rows[0];
        user.app_role = profile?.role || 'user';
        user.is_super_admin = user.is_super_admin || profile?.is_super_admin || false;
        user.session_version = Number(user.raw_user_meta_data?.session_version ?? 0);

        await pool.query('UPDATE auth.users SET last_sign_in_at = now() WHERE id = $1', [user.id]);

        const token = signToken(await freshRoles(pool,user));
        const refresh = await issueRefresh(pool,user);

        return res.json({
          access_token: token,
          token_type: 'bearer',
          expires_in: 900,
          refresh_token: refresh,
          user: {
            id: user.id,
            email: user.email,
            created_at: user.created_at,
            email_confirmed_at: user.email_confirmed_at,
            app_metadata: { provider: 'email', role: user.app_role },
            user_metadata: { display_name: profile?.display_name },
            is_super_admin: user.is_super_admin,
          },
        });
      }

      if (grantType === 'refresh_token') {
        const client=await pool.connect();
        try {
          await client.query('BEGIN');
          const user=await consumeRefresh(client,req.body?.refresh_token);
          if(!user) {await client.query('COMMIT');return res.status(401).json({error:'Invalid refresh token'});}
          const current=await freshRoles(client,user);
          const refresh=await issueRefresh(client,current);
          const token=signToken(current);
          await client.query('COMMIT');
          return res.json({access_token:token,token_type:'bearer',expires_in:900,refresh_token:refresh,user:{id:user.id,email:user.email}});
        } catch(error) {await client.query('ROLLBACK');throw error;}
        finally {client.release();}
      }

      res.status(400).json({ error: 'Unsupported grant_type' });
    } catch (err) {
      console.error('[Auth] Token error:', err.message);
      res.status(500).json({ error: 'Authentication failed' });
    }
  });

  router.post('/logout', requireAuth, async (req,res) => {
    try {
    await pool.query(`UPDATE auth.users SET raw_user_meta_data=jsonb_set(COALESCE(raw_user_meta_data,'{}'::jsonb),'{session_version}',to_jsonb(COALESCE((raw_user_meta_data->>'session_version')::integer,0)+1)) WHERE id=$1`,[req.user.id]);
    await pool.query('DELETE FROM public.api_refresh_sessions WHERE user_id=$1',[req.user.id]);
    res.status(204).end();
    } catch { res.status(503).json({error:'Unable to revoke session'}); }
  });
}
