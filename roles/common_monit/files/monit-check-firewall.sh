#!/bin/bash
# Managed by Ansible (common_monit) - do not edit manually.
# Monit `check program` helper: verifies the nftables firewall is not just
# "loaded" but actually enforcing - the inet/filter input chain must default
# to drop. A stronger signal than the oneshot nftables unit being "active".
if nft list chain inet filter input 2>/dev/null | grep -q "hook input.*policy drop"; then
    exit 0
fi
echo "nftables inet/filter input chain is NOT default-drop - the firewall may be down or flushed."
exit 1
