ALTER TABLE public.role_change_logs
DROP CONSTRAINT IF EXISTS role_change_logs_action_check;

ALTER TABLE public.role_change_logs
ADD CONSTRAINT role_change_logs_action_check
CHECK (action IN (
  'invited',
  'accepted',
  'declined',
  'revoked',
  'expired',
  'assigned',
  'invitation_cancelled',
  'blocked',
  'unblocked',
  'balance_changed',
  'user_deleted',
  'impersonation_started',
  'impersonation_ended',
  'profile_updated',
  'track_deleted',
  'moderation_sent_to_voting',
  'moderation_approved',
  'moderation_rejected',
  'distribution_approved',
  'distribution_rejected',
  'deposit_approved',
  'deposit_rejected',
  'setting_changed',
  'contest_created',
  'contest_updated',
  'contest_deleted'
));
