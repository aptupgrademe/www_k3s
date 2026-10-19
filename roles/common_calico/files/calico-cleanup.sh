#!/bin/bash
# Managed by Ansible (common_calico) - removes what Calico's Felix left on the
# host after its pods were deleted. Felix does not clean up on removal; its
# rules would stay until the next reboot. Only Calico's own objects are
# touched: rules in the built-in chains whose comment starts with "cali:",
# the cali-* chains, the cali* ipsets and the nftables table "arp calico-arp".
# Rules of kube-proxy, Flannel and K3s's policy controller stay as they are.
# Prints one line per removed object; silent when there is nothing left.
set -u
for fam in iptables-nft ip6tables-nft; do
    for t in raw mangle nat filter; do
        # rules in built-in chains that belong to Calico -> delete them one by one
        "$fam-save" -t "$t" 2>/dev/null \
          | grep -E '^-A (PREROUTING|INPUT|FORWARD|OUTPUT|POSTROUTING) ' \
          | grep -E 'cali:|-j cali-' \
          | sed 's/^-A /-D /' \
          | while read -r rule; do
              eval "$fam -t $t $rule" && echo "$fam -t $t: removed $(echo "$rule" | cut -c1-60)"
            done
        # then the cali-* chains themselves: flush all first, then delete
        chains=$("$fam-save" -t "$t" 2>/dev/null | sed -n 's/^:\(cali-[^ ]*\) .*/\1/p')
        for c in $chains; do "$fam" -t "$t" -F "$c"; done
        for c in $chains; do "$fam" -t "$t" -X "$c" && echo "$fam -t $t: chain $c deleted"; done
    done
done
for s in $(ipset list -n 2>/dev/null | grep '^cali'); do ipset destroy "$s" && echo "ipset $s destroyed"; done
if nft list table arp calico-arp >/dev/null 2>&1; then nft delete table arp calico-arp && echo "nft table arp calico-arp deleted"; fi
rm -rf /var/lib/calico /var/run/calico
exit 0
