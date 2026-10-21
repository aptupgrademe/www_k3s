# K8s apply test

Checks the Kubernetes-facing part of the roles (`common_k3s`,
`blog_k3s_deploy`, `next_k3s_deploy`) without touching a server: an
API-server-only K3s of the pinned `k3s_version` runs in podman, the manifests
are applied first with the roles of `main` (the state the servers are in) and
then with the working tree's roles.

```bash
tests/k8s/run.sh            # compare against main
tests/k8s/run.sh <git-ref>  # compare against another branch/commit
```

It fails when

- the second real run of the new roles still changes something,
- a `--check` run after it reports changes,
- a Deployment rolled out a new ReplicaSet (pod restart) or a Helm release got
  a new revision during the test,
- a deliberately changed image tag / chart version is *not* detected by
  `--check` (negative test).

## What it does not cover

There is no kubelet, so no pod ever runs. Commands that need pods
(`kubectl exec`, `logs`, `rollout status`, `wait`) are answered by a stub
(`k3s-stub`); everything that runs *inside* the pods (occ, wp-cli, the MariaDB
exporter user) is out of scope - `ALLOW_CHANGED` in `run.sh` lists the one task
that therefore always reports a change here. Host-level roles (firewall, SSH,
SELinux, ...) are not part of this test; for those, use the drift check on the
real servers:

```bash
scripts/check-drift.sh nextcloud-k3s.yml cvjm --ask-vault-pass
```

## Requirements

- podman (rootless is fine: the API server needs no cgroup delegation)
- curl (downloads the pinned Helm release)
- the collections from `requirements.yml`
- a Python with the `kubernetes` package for the kubernetes.core modules:

```bash
python3 -m venv ~/.venvs/k8s-test && ~/.venvs/k8s-test/bin/pip install kubernetes
K8S_TEST_PYTHON=~/.venvs/k8s-test/bin/python tests/k8s/run.sh
```

`K8S_TEST_KEEP=1` leaves the cluster running afterwards; the files of the last
run (JSON results per step, rendered role copies) are in `tests/k8s/.work/`.
