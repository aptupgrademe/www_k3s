#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: warns before a TLS certificate actually
# expires. cert-manager renews at 30 days remaining, so anything still under
# MIN_DAYS means renewal has been failing for a while and nobody noticed -
# the exact failure mode that took this stack down once already (an image
# allowlist silently blocked cert-manager's ACME solver pod, so issuance
# never completed; without this check that only surfaces when the old cert
# expires and the site goes dark).
#
# Hostnames come from the Ingress resources themselves rather than a config
# list here, so a newly added Ingress is covered automatically.
#
# Checks what is actually *served* on :443 via SNI over 127.0.0.1 - not the
# contents of the K8s secret - because that is what a browser really gets,
# and it needs no working public DNS to run.

MIN_DAYS="${1:-21}"

command -v k3s >/dev/null 2>&1 || exit 0
command -v openssl >/dev/null 2>&1 || exit 0

hosts=$(k3s kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.tls[*]}{range .hosts[*]}{@}{"\n"}{end}{end}{end}' 2>/dev/null | sort -u)
[ -z "$hosts" ] && exit 0

problems=""

for host in $hosts; do
    cert=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null)
    if [ -z "$cert" ]; then
        problems="$problems; $host: no certificate served (TLS handshake failed)"
        continue
    fi

    end=$(echo "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$end" ]; then
        problems="$problems; $host: could not read certificate expiry"
        continue
    fi

    left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))

    # A self-signed cert here is the placeholder seeded at deploy time so the
    # ingress has something to serve until cert-manager issues the real one.
    # It means issuance has not completed - report that, not just "expires soon".
    subject=$(echo "$cert" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(echo "$cert" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    if [ "$subject" = "$issuer" ]; then
        problems="$problems; $host: still on the self-signed placeholder - cert-manager has not issued a real certificate (${left}d left)"
        continue
    fi

    if [ "$left" -lt "$MIN_DAYS" ]; then
        problems="$problems; $host: expires in ${left}d (renewal should have happened at 30d)"
    fi
done

[ -z "$problems" ] && exit 0
echo "TLS certificate problems${problems}"
exit 1
