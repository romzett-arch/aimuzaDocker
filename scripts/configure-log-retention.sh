#!/usr/bin/env bash
set -euo pipefail
[[ "$(id -u)" == 0 ]] || { echo 'Root is required'; exit 1; }
command -v logrotate >/dev/null
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/aimuza-retention.conf <<'EOF'
[Journal]
MaxRetentionSec=7day
MaxFileSec=1day
SystemMaxUse=512M
SystemMaxFileSize=32M
RuntimeMaxUse=128M
EOF

# Keep vendor paths, permissions and postrotate hooks; shorten only retention directives.
# Includes nginx, rsyslog, ufw, apt, wtmp/btmp and other installed system log definitions.
for config in /etc/logrotate.conf /etc/logrotate.d/*; do
  [[ -f "$config" ]] || continue
  temporary="$(mktemp)"
  awk '
    /^[[:space:]]*(daily|weekly|monthly|yearly)[[:space:]]*$/ { print "    daily"; next }
    /^[[:space:]]*rotate[[:space:]]+[0-9]+[[:space:]]*$/ { print "    rotate 7\n    maxage 7"; next }
    /^[[:space:]]*maxage[[:space:]]+[0-9]+[[:space:]]*$/ { next }
    { print }
  ' "$config" > "$temporary"
  cat "$temporary" > "$config"
  rm -f "$temporary"
done
logrotate --debug /etc/logrotate.conf >/dev/null
systemctl restart systemd-journald
systemctl enable --now logrotate.timer
journalctl --rotate
journalctl --vacuum-time=7d --vacuum-size=512M
echo 'System/application journal: at most 7 days, 512 MiB total; text logs: daily, 7 rotations.'
