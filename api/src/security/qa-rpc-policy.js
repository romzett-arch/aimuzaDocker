export function assertQaRpcAccess(fnName, user, params = {}) {
  const authenticatedFunctions = new Set([
    'qa_increment_reports_total', 'vote_qa_ticket', 'create_support_ticket',
  ]);
  const staffFunctions = new Set([
    'resolve_qa_ticket', 'qa_recalculate_priority', 'promote_support_ticket_to_qa',
  ]);

  if (!authenticatedFunctions.has(fnName) && !staffFunctions.has(fnName)) return params;

  if (!user?.id) {
    const error = new Error('Необходимо войти в систему');
    error.status = 401;
    throw error;
  }

  if (staffFunctions.has(fnName) && user.role !== 'service_role') {
    const role = String(user.app_role || '').toLowerCase();
    if (!['moderator', 'admin', 'super_admin', 'superadmin'].includes(role)) {
      const error = new Error('Требуются права сотрудника поддержки');
      error.status = 403;
      throw error;
    }
  }

  if (fnName === 'qa_increment_reports_total' && user.role !== 'service_role') {
    params.p_user_id = user.id;
  }

  return params;
}
