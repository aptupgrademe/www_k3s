#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: flags K3s pods stuck in a clearly-bad state
# (crash loop, image pull error, OOM, ...). Transient ContainerCreating /
# Pending is intentionally ignored to avoid false alarms on brief restarts.
command -v k3s >/dev/null 2>&1 || exit 0
bad=$(k3s kubectl get pods -A --no-headers 2>/dev/null \
    | grep -iE "CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|[[:space:]]Error[[:space:]]" \
    | awk '{print $1"/"$2" ("$4")"}' | paste -sd', ' -)
[ -z "$bad" ] && exit 0
echo "K3s pods in a bad state: $bad"
exit 1
