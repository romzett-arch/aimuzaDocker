#!/bin/bash
# Prepared locally. Never invoked by application deployment.
set -euo pipefail
if [ "${1:-}" != '--apply' ] || [ "${CONFIRMED_PROVIDER_CONSOLE:-}" != 'yes' ]; then
  echo 'No changes. Requires --apply, CONFIRMED_PROVIDER_CONSOLE=yes and SSH_ADMIN_CIDR after testing a second key-only session.' >&2
  exit 1
fi
: "${SSH_ADMIN_CIDR:?Explicit trusted administrator CIDR required}"
[[ "$SSH_ADMIN_CIDR" =~ ^[0-9a-fA-F.:]+/[0-9]{1,3}$ ]] || { echo 'Invalid administrator CIDR' >&2; exit 1; }
test "$(id -u)" = 0
test -n "${SSH_CONNECTION:-}"
command -v ufw >/dev/null
/usr/sbin/sshd -t
test -s /root/.ssh/authorized_keys
# No rule reset: existing operator rules must be reviewed separately.
ufw allow from "$SSH_ADMIN_CIDR" to any port 22 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
install -m 0644 "$(dirname "$0")/90-aimuza-hardening.conf" /etc/ssh/sshd_config.d/90-aimuza-hardening.conf
/usr/sbin/sshd -t
# Verify effective settings; earlier distro snippets can override later ones.
effective=$(/usr/sbin/sshd -T)
grep -qx 'passwordauthentication no' <<< "$effective"
grep -qx 'kbdinteractiveauthentication no' <<< "$effective"
systemctl reload ssh
echo 'Open and verify a second SSH session before closing this one. Review IPv6 and monitoring rules.'
