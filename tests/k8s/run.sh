#!/bin/bash
# =============================================================================
# K8s apply test - see README.md in this directory.
#
#   tests/k8s/run.sh            compare against main (state main leaves behind)
#   tests/k8s/run.sh <git-ref>  compare against another commit/branch
#
# 1. starts an API-only K3s (same version as k3s_version) in podman
# 2. applies the K8s manifests with the roles of <git-ref>   -> "old" state
# 3. runs the working tree's roles on top: --check, real, real, --check
# 4. negative test: a changed image tag and chart version must be detected
# Fails (exit 1) if the second real run or the final --check changes anything,
# if a Deployment rolled out a new ReplicaSet, a Helm release got a new
# revision, or the negative test misses a change.
# Needs: podman (rootless is fine), curl, and a Python with the "kubernetes"
# package for the kubernetes.core modules (K8S_TEST_PYTHON, see README.md).
# =============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BASE_REF=${1:-main}
WORK=$HERE/.work                      # gitignored
CONTAINER=www-k3s-apitest
PORT=${K8S_TEST_PORT:-16443}
PY=${K8S_TEST_PYTHON:-python3}
# Pods that never run can not satisfy these; anything else changing on the
# second run is a real idempotency problem.
ALLOW_CHANGED='mysqld_exporter database user'   # kubectl exec is stubbed

K3S_VERSION=$(grep -oP '^k3s_version:\s*"\K[^"]+' "$REPO/inventory/group_vars/all/versions.yml")
HELM_VERSION=$(grep -oP '^helm_version:\s*"\K[^"]+' "$REPO/inventory/group_vars/all/versions.yml")

"$PY" -c 'import kubernetes' 2>/dev/null || {
  echo "Python '$PY' has no 'kubernetes' package - see README.md (K8S_TEST_PYTHON)." >&2; exit 2; }

rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/tmpk8s" "$WORK/nginxdef"
cp "$HERE/k3s-stub" "$WORK/bin/k3s"
echo "== helm $HELM_VERSION"
curl -sSfL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  | tar xz -C "$WORK" linux-amd64/helm
mv "$WORK/linux-amd64/helm" "$WORK/bin/helm"

# --- role trees: old = <BASE_REF>, new = working tree ------------------------
mkdir -p "$WORK/old" "$WORK/new"
git -C "$REPO" archive "$BASE_REF" roles | tar x -C "$WORK/old"
cp -r "$REPO/roles" "$WORK/new/"
# Test-only adjustments, identical for both trees: host paths the roles
# write to (/tmp, /etc) go into $WORK, and Helm must not wait for pods.
for t in old new; do
  R=$WORK/$t/roles
  grep -rlE "/tmp/k8s-|/tmp/placeholder|/etc/ingress-nginx-defaults|/tmp/ingress-nginx-values|/etc/rancher/k3s/k3s.yaml" \
    "$R"/{common_k3s,common_calico,blog_k3s_deploy,next_k3s_deploy} | xargs -r sed -i \
    -e "s#/tmp/k8s-#$WORK/tmpk8s/k8s-#g" -e "s#/tmp/placeholder#$WORK/tmpk8s/placeholder#g" \
    -e "s#/etc/ingress-nginx-defaults#$WORK/nginxdef#g" \
    -e "s#/tmp/ingress-nginx-values#$WORK/tmpk8s/ingress-nginx-values#g" \
    -e "s#/etc/rancher/k3s/k3s.yaml#$WORK/kubeconfig#g"
  sed -i '/path: .*nginxdef$/,/mode:/{/owner: root/d;/group: root/d}' "$R/common_k3s/tasks/nginx_ingress.yml"
  # "helm upgrade --install ... --wait" (CLI, older roles) / "wait: true" (module)
  sed -i -e '/^    --wait$/d' -e 's/^    wait: true$/    wait: false/' \
    -e 's/^    --set crds.enabled=true$/    --set crds.enabled=true --set startupapicheck.enabled=false/' \
    "$R"/common_k3s/tasks/{cert_manager,nginx_ingress}.yml
  "$PY" - "$R/common_k3s/tasks/cert_manager.yml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
# cert-manager's post-install check Job never completes without pods
p.write_text(t.replace("      crds:\n        enabled: true\n",
                       "      crds:\n        enabled: true\n      startupapicheck:\n        enabled: false\n"))
PY
done

# --- cluster -----------------------------------------------------------------
echo "== K3s $K3S_VERSION (API server only)"
podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
podman run -d --name "$CONTAINER" --privileged --tmpfs /run --tmpfs /var/run \
  -v "$WORK:$WORK:z" -p "127.0.0.1:$PORT:6443" \
  "docker.io/rancher/k3s:${K3S_VERSION/+/-}" server --disable-agent \
  --disable traefik --disable servicelb --disable metrics-server --disable local-storage \
  --tls-san 127.0.0.1 >/dev/null
for _ in $(seq 1 60); do podman exec "$CONTAINER" kubectl get ns default >/dev/null 2>&1 && break; sleep 2; done
podman exec "$CONTAINER" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$PORT#" > "$WORK/kubeconfig"
chmod 600 "$WORK/kubeconfig"

# cert-manager's admission webhook has no pod behind it here, so every
# cert-manager.io write would be rejected: drop its configs whenever Helm
# (re)creates them.
( while true; do
    podman exec "$CONTAINER" kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
      cert-manager-webhook --ignore-not-found >/dev/null 2>&1 || true
    sleep 1
  done ) &
REAPER=$!
# K8S_TEST_KEEP=1 leaves the cluster running afterwards (debugging,
# scripts/check-drift.sh against it - see README.md).
if [ "${K8S_TEST_KEEP:-0}" = 1 ]; then
  trap 'kill $REAPER 2>/dev/null' EXIT
else
  trap 'kill $REAPER 2>/dev/null; podman rm -f "$CONTAINER" >/dev/null 2>&1' EXIT
fi

cat > "$WORK/inventory.yml" <<EOF
all:
  hosts:
    testnode:
      ansible_connection: local
      ansible_python_interpreter: $(command -v "$PY")
EOF

FAIL=0
# run <tree> <name> [ansible-playbook args]: prints the changed tasks
run() {
  local tree=$1 name=$2; shift 2
  ANSIBLE_ROLES_PATH=$WORK/$tree/roles ANSIBLE_CONFIG=$REPO/ansible.cfg \
  ANSIBLE_STDOUT_CALLBACK=ansible.posix.json ANSIBLE_CALLBACKS_ENABLED=profile_tasks \
    ansible-playbook -i "$WORK/inventory.yml" "$HERE/play.yml" \
      -e "@$HERE/overrides.yml" -e "work=$WORK" -e "container=$CONTAINER" \
      -e "k3s_kubeconfig=$WORK/kubeconfig" "$@" </dev/null > "$WORK/$name.json" 2> "$WORK/$name.err" || {
    echo "!! $name: ansible-playbook failed, see $WORK/$name.json"; FAIL=1; return 0; }
  "$PY" - "$WORK/$name.json" > "$WORK/$name.changed" <<'PY'
import json, sys
# profile_tasks (ansible.cfg) prints timing lines around the JSON document
s = open(sys.argv[1]).read()
d, _ = json.JSONDecoder().raw_decode(s[s.index("{\n"):])
for play in d["plays"]:
    for t in play["tasks"]:
        for host, r in t["hosts"].items():
            if r.get("changed"):
                print(t["task"]["name"])
PY
  printf '== %-10s changed tasks: %s\n' "$name" "$(wc -l < "$WORK/$name.changed")"
}

run old old                         # state as <BASE_REF> leaves it
run new check1 --check
run new real1                       # one-time migration run
run new real2                       # must be idempotent now
run new check2 --check

if grep -vE "$ALLOW_CHANGED" "$WORK/real2.changed" | grep -q .; then
  echo "!! second run still changed:"; grep -vE "$ALLOW_CHANGED" "$WORK/real2.changed" | sed 's/^/     /'; FAIL=1
fi
if grep -vE "$ALLOW_CHANGED" "$WORK/check2.changed" | grep -q .; then
  echo "!! final --check still reports changes:"; grep -vE "$ALLOW_CHANGED" "$WORK/check2.changed" | sed 's/^/     /'; FAIL=1
fi
NEW_RS=$(podman exec "$CONTAINER" kubectl get rs -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,N:.metadata.name,R:.metadata.annotations.deployment\.kubernetes\.io/revision' \
  | awk '$3 != 1')
[ -z "$NEW_RS" ] || { echo "!! Deployments rolled out again:"; echo "$NEW_RS"; FAIL=1; }
NEW_REV=$(KUBECONFIG=$WORK/kubeconfig HELM_CACHE_HOME=$WORK/helm/cache HELM_CONFIG_HOME=$WORK/helm/config \
  HELM_DATA_HOME=$WORK/helm/data "$WORK/bin/helm" list -A | awk 'NR > 1 && $3 != 1')
[ -z "$NEW_REV" ] || { echo "!! new Helm revisions:"; echo "$NEW_REV"; FAIL=1; }

# Negative test: these two changes must show up in --check, nothing else.
run new negative --check -e blog_image_redis=redis:0.0.0-test -e cert_manager_chart_version=1.0.0
for want in 'Redis | Apply Deployment' 'cert-manager | Install/upgrade cert-manager'; do
  grep -qF "$want" "$WORK/negative.changed" || { echo "!! negative test missed: $want"; FAIL=1; }
done

[ "$FAIL" = 0 ] && echo "== PASSED" || echo "== FAILED"
exit "$FAIL"
