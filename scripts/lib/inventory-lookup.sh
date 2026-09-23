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

    # Host and port on separate lines: with "read -r A B" an empty host let the
    # port slide into REMOTE_HOST ("10022") instead of triggering the error below.
    { read -r REMOTE_HOST; read -r REMOTE_SSH_PORT; } <<<"$(python3 - "$repo_root" "$want" <<'PY'
import sys, os, re, yaml

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

hostvars = {}
try:
    with open(os.path.join(repo, "inventory", "host_vars", want, "vars.yml")) as fh:
        hostvars = yaml.safe_load(fh) or {}
except Exception:
    pass

# ansible_host lives in host_vars/<host>/vars.yml (usually "{{ server_ipv4 }}",
# the single source of truth); inventory/hosts.yml is only a fallback for
# setups that still keep it there.
host = hostvars.get("ansible_host") or ""
if not host:
    try:
        with open(os.path.join(repo, "inventory", "hosts.yml")) as fh:
            host = find_host(yaml.safe_load(fh)) or ""
    except Exception:
        pass
m = re.fullmatch(r"\{\{\s*(\w+)\s*\}\}", str(host).strip())
if m:
    host = hostvars.get(m.group(1), "")
if "{{" in str(host):
    host = ""   # a more complex template this helper can't evaluate

print(host)
print(hostvars.get("ansible_port", ""))
PY
)"

    if [[ -z "$REMOTE_HOST" ]]; then
        echo "Error: no ansible_host for '$want' in host_vars/$want/vars.yml or inventory/hosts.yml." >&2
        echo "Copy host_vars/$want/vars.yml.example -> vars.yml and set server_ipv4" >&2
        echo "(ansible_host points to it) and ansible_port; list the host in inventory/hosts.yml." >&2
        exit 1
    fi

    # Fresh servers are still on 22 until common_ssh has run.
    REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"
}
