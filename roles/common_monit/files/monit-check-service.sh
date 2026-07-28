#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: exits 0 if the given systemd service is active,
# non-zero otherwise (printing the actual state for the alert body). This is
# the exact failure that went unnoticed with fail2ban before Monit existed.
s="$1"
if systemctl is-active --quiet "$s"; then
    exit 0
fi
echo "systemd service '$s' is $(systemctl is-active "$s" 2>&1) (expected: active)"
exit 1
