#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: every address fail2ban considers banned must
# really be in that jail's nftables set - otherwise fail2ban says "banned" and
# the firewall lets it through.
#
# Why this exists: on 2026-10-21 a comparison found 1 to 5 such addresses per
# host. All jails shared one set, and the 1-hour unban of nginx-k3s-scanner
# deleted addresses that nginx-k3s-bad-paths had banned for 24 h. Since then
# every jail has its own set (fail2ban_nft_jails); this check proves it stays
# that way, and would also catch a firewall reload that emptied the sets
# without fail2ban re-applying its bans.
#
# The set name comes from fail2ban itself (the action's setname property), so
# this script needs no list of its own. An address that is missing is checked
# again after a few seconds - a ban that is being applied right now is not a
# finding.

command -v fail2ban-client >/dev/null 2>&1 || exit 0
command -v nft >/dev/null 2>&1 || exit 0
systemctl is-active --quiet fail2ban 2>/dev/null || exit 0   # the service check covers that

in_set() {   # in_set <setname-without-family> <ip>
    local fam=4
    [[ $2 == *:* ]] && fam=6
    nft get element inet filter "${1}${fam}" "{ $2 }" >/dev/null 2>&1
}

missing=""
for jail in $(fail2ban-client status 2>/dev/null \
        | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
    set=$(fail2ban-client get "$jail" action nftables-banned-sets setname 2>/dev/null)
    [ -n "$set" ] || set=banned
    for ip in $(fail2ban-client get "$jail" banip 2>/dev/null); do
        in_set "$set" "$ip" && continue
        sleep 5
        in_set "$set" "$ip" || missing="$missing $jail:$ip(${set})"
    done
done

if [ -n "$missing" ]; then
    echo "banned in fail2ban but NOT in the nftables set:$missing"
    echo "Remedy: systemctl restart fail2ban (re-applies every active ban), then look for the cause."
    exit 1
fi
exit 0
