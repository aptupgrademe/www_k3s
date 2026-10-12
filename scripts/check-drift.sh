#!/bin/bash
# =============================================================================
# Drift check: what would a real playbook run change on a host right now?
#
#   scripts/check-drift.sh <playbook> <host> [more ansible-playbook args]
#   scripts/check-drift.sh nextcloud-k3s.yml cvjm
#   scripts/check-drift.sh blog.yml www.apt-upgrade.me --tags blog_k3s_deploy
#
# Runs the playbook with --check --diff (nothing is changed on the host) and
# prints only the tasks that would change, with their diff. Exit code 0 = no
# drift (the host is exactly what the code describes), 1 = drift, 2 = the
# check run itself failed. Right after a real run this must report no drift -
# anything listed then is a task that is not idempotent.
#
# Vault: uses vault_password_file from ansible.cfg if set, otherwise pass
# --ask-vault-pass (or --vault-password-file <file>) as an extra argument.
# =============================================================================
set -euo pipefail

[ $# -ge 2 ] || { sed -n '3,9p' "$0"; exit 2; }
PLAYBOOK=$1 HOST=$2; shift 2
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cd "$REPO"
INV=(-i inventory/hosts.yml)
for a in "$@"; do case "$a" in -i|--inventory|-i*|--inventory=*) INV=();; esac; done
set +e
ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
  ansible-playbook "${INV[@]}" "$PLAYBOOK" --limit "$HOST" --check --diff "$@" > "$OUT/run.json"
RC=$?
set -e
# DRIFT_KEEP_JSON=<file>: keep the raw ansible.posix.json output for a closer look
if [ -n "${DRIFT_KEEP_JSON:-}" ]; then cp "$OUT/run.json" "$DRIFT_KEEP_JSON"; fi

python3 - "$OUT/run.json" "$RC" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
rc = int(sys.argv[2])
try:
    # profile_tasks (ansible.cfg) prints timing lines around the JSON document
    data, _ = json.JSONDecoder().raw_decode(raw[raw.index("{\n"):])
except ValueError:
    print(raw[-3000:]); print("\n!! check run produced no result (see above)"); sys.exit(2)

import difflib, yaml

NOISE = ("managedFields", "resourceVersion", "generation", "uid", "creationTimestamp")
def text(obj):
    """Kubernetes objects come as dicts: drop server bookkeeping, render YAML."""
    if isinstance(obj, dict):
        obj = json.loads(json.dumps(obj))
        md = obj.get("metadata", {})
        for k in NOISE:
            md.pop(k, None)
        md.get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
        if md.get("annotations") == {}:
            md.pop("annotations")
        obj.pop("status", None)
        return yaml.safe_dump(obj, default_flow_style=False, sort_keys=True)
    return str(obj)

def diffs(r):
    """yield readable diff text of one result (or of each loop item)."""
    items = r.get("results")
    # some modules (dnf, ...) return "results" as a list of strings, not per-item dicts
    if not (isinstance(items, list) and items and all(isinstance(i, dict) for i in items)):
        items = [r]
    for res in items:
        if not res.get("changed"):
            continue
        label = res.get("_ansible_item_label", res.get("item"))
        if res.get("_ansible_no_log") or res.get("censored"):
            yield label, "(no_log: content hidden)"; continue
        raw = res.get("diff")
        for d in raw if isinstance(raw, list) else [raw or {}]:
            if isinstance(d, str):
                yield label, d; continue
            if "prepared" in d:
                yield label, d["prepared"]
            elif "before" in d or "after" in d:
                b, a = text(d.get("before", "")), text(d.get("after", ""))
                yield label, "\n".join(difflib.unified_diff(b.splitlines(), a.splitlines(),
                                                            d.get("before_header", "before"),
                                                            d.get("after_header", "after"), lineterm=""))
            else:
                yield label, res.get("msg", "")

changed, failed = [], []
for play in data["plays"]:
    for t in play["tasks"]:
        for host, r in t["hosts"].items():
            if r.get("failed") and not r.get("ignore_errors"):
                failed.append((t["task"]["name"], r.get("msg", "")))
            elif r.get("changed"):
                changed.append((t["task"]["name"], list(diffs(r))))

for name, ds in changed:
    print(f"\n### would change: {name}")
    for label, text in ds:
        if label: print(f"  -- {label}")
        for line in str(text).splitlines()[:60]:
            print("    " + line)
for name, msg in failed:
    print(f"\n!!! failed in check mode: {name}\n    {str(msg)[:500]}")

stats = data.get("stats", {})
print("\n" + ", ".join(f"{h}: changed={s['changed']} failed={s['failures']}" for h, s in stats.items()))
if failed or rc not in (0, 2):
    sys.exit(2)
print("NO DRIFT" if not changed else f"DRIFT: {len(changed)} task(s) would change")
sys.exit(1 if changed else 0)
PY
