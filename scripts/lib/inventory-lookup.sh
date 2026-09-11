#!/bin/bash
# Managed by Ansible repo - sourced by the backup/restore scripts.
#
# Resolves a server's address and SSH port from the Ansible inventory instead
# of hardcoding them in each script. inventory/hosts.yml and
# host_vars/*/vars.yml are gitignored precisely because they hold real
# addresses - repeating those values in a tracked script would publish them
# (this repo goes to GitHub) and create a second place to keep in sync, which
# already drifted once: a script pinned SSH port 22 for a host the inventory
# had long since moved to 10022.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/inventory-lookup.sh"
#   inventory_lookup <host-name-as-in-hosts.yml>
# Sets REMOTE_HOST and REMOTE_SSH_PORT, or exits with an actionable message.

inventory_lookup() {
    local want="$1"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    read -r REMOTE_HOST REMOTE_SSH_PORT <<<"$(python3 - "$repo_root" "$want" <<'PY'
import sys, os, yaml

repo, want = sys.argv[1], sys.argv[2]

def find_host(node):
    """Walk the inventory tree; group nesting is arbitrary, so recurse."""
    if not isinstance(node, dict):
        return None
    for key, val in node.items():
        if key == "hosts" and isinstance(val, dict) and want in val:
            return (val[want] or {}).get("ansible_host")
        found = find_host(val)
        if found:
            return found
    return None

host = port = ""
try:
    with open(os.path.join(repo, "inventory", "hosts.yml")) as fh:
        host = find_host(yaml.safe_load(fh)) or ""
except Exception:
    pass
try:
    with open(os.path.join(repo, "inventory", "host_vars", want, "vars.yml")) as fh:
        port = (yaml.safe_load(fh) or {}).get("ansible_port", "")
except Exception:
    pass

print(host, port)
PY
)"

    if [[ -z "$REMOTE_HOST" ]]; then
        echo "Error: no ansible_host for '$want' in inventory/hosts.yml." >&2
        echo "Copy inventory/hosts.yml.example -> hosts.yml and fill in the real" >&2
        echo "address, and host_vars/$want/vars.yml.example -> vars.yml for the port." >&2
        exit 1
    fi

    # Fresh servers are still on 22 until common_ssh has run.
    REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"
}
