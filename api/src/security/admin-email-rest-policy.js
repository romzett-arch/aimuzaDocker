const ADMIN_EMAIL_TABLE = 'admin_emails';

function forbidden() {
  const error = new Error('Недостаточно прав для управления историей рассылок');
  error.status = 403;
  error.code = 'ADMIN_EMAIL_ACCESS_DENIED';
  return error;
}

export async function assertAdminEmailAccess(client, table, user) {
  if (table !== ADMIN_EMAIL_TABLE || user?.role === 'service_role') return;
  if (!user?.id) throw forbidden();

  const { rowCount } = await client.query(
    `SELECT 1
       FROM public.user_roles
      WHERE user_id = $1::uuid
        AND role IN ('admin', 'super_admin')
      LIMIT 1`,
    [user.id],
  );

  if (rowCount === 0) throw forbidden();
}
