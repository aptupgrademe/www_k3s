#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: verifies the fail2ban jails that watch K3s pod
# logs are actually watching a file, not just "running".
#
# Why this exists: those jails point at
#   /var/log/pods/ingress-nginx_ingress-nginx-*/nginx-ingress/*.log
# and the pod UID in that path changes every time the ingress pod is recreated
# (image update, helm upgrade, node reboot, rescheduling). fail2ban resolves
# the glob only at start, so after any such restart the jail keeps running with
# a file list pointing at a path that no longer exists - it can never ban
# anyone again. Found live 2026-09-11: a helm upgrade that morning had silently
# disabled all five web jails, and nothing noticed, because monit's other check
# only asks whether the fail2ban *process* is alive.
#
# Remedy when this fires: `systemctl restart fail2ban` re-resolves the globs.

command -v fail2ban-client >/dev/null 2>&1 || exit 0
systemctl is-active --quiet fail2ban 2>/dev/null || exit 0   # the service check covers that

empty=""
for jail in $(fail2ban-client status 2>/dev/null \
        | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
    # Only file-backed jails; sshd uses the systemd journal and has no file list.
    case "$jail" in
        nginx-*) ;;
        *) continue ;;
    esac
    files=$(fail2ban-client status "$jail" 2>/dev/null \
        | sed -n 's/.*File list:[[:space:]]*//p' | tr -d '[:space:]')
    [ -z "$files" ] && empty="$empty $jail"
done

[ -z "$empty" ] && exit 0
echo "fail2ban jails watching no log file (ingress pod was probably recreated):${empty}. Fix: systemctl restart fail2ban"
exit 1
