# Homelab Ansible – Nextcloud & WordPress

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Ansible](https://img.shields.io/badge/Ansible-2.15+-red.svg)](https://www.ansible.com/)
[![K3s](https://img.shields.io/badge/K3s-latest-blue.svg)](https://k3s.io/)
[![AlmaLinux](https://img.shields.io/badge/AlmaLinux-9-green.svg)](https://almalinux.org/)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-34-0082C9.svg)](https://nextcloud.com/)
[![WordPress](https://img.shields.io/badge/WordPress-7.1.0-21759B.svg)](https://wordpress.org/)

Ansible playbooks to deploy and manage internet-facing servers
(K3s on AlmaLinux 9) fully automated.

The goal is to be able to rebuild any machine from scratch using a single
`ansible-playbook` command.

Two independent deployment scenarios:

| Scenario | Playbook | Target | What gets deployed |
|---|---|---|---|
| **Nextcloud** | `nextcloud-k3s.yml` | Internet VPS (AlmaLinux 9) | Nextcloud + Collabora CODE (online office) on K3s |
| **WordPress** | `blog.yml` | Internet VPS (AlmaLinux 9) | WordPress blog on K3s |

Both scenarios share a common infrastructure layer (K3s, nginx-ingress,
cert-manager, Prometheus, Grafana, Fail2Ban, nftables hardening).

---

## Architecture

### Internet Servers (AlmaLinux 9 + K3s)

```
Internet
    │  HTTPS (443) / HTTP (80 → redirect)
    ▼
┌─────────────────────────────────────────────────────────────┐
│  AlmaLinux 9 Host                                           │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  K3s (single-node Kubernetes)                       │    │
│  │                                                     │    │
│  │  nginx-ingress  (F5, hostNetwork, ports 80/443)    │    │  ← TLS, Brotli, HTTP/2
│  │  cert-manager   (Let's Encrypt – auto TLS)         │    │
│  │  NetworkPolicy: K3s policy controller (kube-router)│    │
│  │                                                     │    │
│  │  ┌──────────────────┐  ┌─────────────────────────┐ │    │
│  │  │  Nextcloud stack │  │   WordPress stack        │ │    │
│  │  │  nextcloud-fpm   │  │   wordpress-fpm          │ │    │
│  │  │  nginx sidecar   │  │   nginx sidecar          │ │    │
│  │  │  Collabora CODE  │  │   MariaDB pod            │ │    │
│  │  └──────────────────┘  │   Redis pod              │ │    │
│  │                        └─────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  Host services: Prometheus · Grafana · Fail2Ban · nftables  │
│  auditd · rkhunter · dnf-automatic · msmtp                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

### Nextcloud & WordPress

- **Nextcloud 34** with PHP-FPM, nginx sidecar, Redis (host service) and MariaDB 10.11
- **Collabora CODE** (online office) with WOPI integration
- **NetworkPolicies on both stacks**, enforced by K3s's embedded policy controller
  (kube-router): on Nextcloud, Collabora can never reach MariaDB/Redis directly, and
  since 2026-10-20 the Nextcloud pod accepts only the ingress controller, Collabora
  and the exporter scrape, notify_push only the ingress controller; on
  the blog, MariaDB/Redis only accept the WordPress pods and WordPress's own egress
  is capped. (Calico ran next to it until 2026-10-19 but never enforced anything –
  see below.)
- **WordPress 7.1** (core 7.1.3 via the nightly minor updates, on the pinned `wordpress:7.1.3` image) with PHP-FPM,
  nginx sidecar, MariaDB pod and **Redis Object Cache** pod
- Automatic installation on first pod start via container env vars and WP-CLI
- WordPress WP-Cron as Kubernetes CronJob (no HTTP trigger); the cron pods carry
  their own label (`app: wordpress-cron`) so the Services never route visitors to them
- **Nightly WordPress updates** – CronJob `wordpress-autoupdate` (03:30 Europe/Berlin):
  DB dump first, then core minor releases, plugins, themes and all language packs via
  WP-CLI, and an HTTP 200 check afterwards. `blog-update.yml` runs the same job on demand and
  re-pulls rebuilt images; `nextcloud-update.yml` is its Nextcloud counterpart (both refuse to run
  without `--limit`)
- **Config changes roll the pod** – a `checksum/config` annotation on the Nextcloud and
  WordPress pod templates restarts the pod once when a rendered ConfigMap changes
  (subPath mounts never update inside a running pod)
- **Pull backups with history** (my local setup, running in my homelab) – a backup machine pulls every Nextcloud instance and
  the blog (rsync + verified DB dump, no maintenance mode) and keeps 30 days of versions
  with rdiff-backup; Monit alerts on the servers when the last success is older than
  3 days (`scripts/nextcloud-backup/`, `scripts/wordpress-backup/`). Optional split setup: an always-on
  NAS pulls at night, the backup PC only versions the NAS copy over SSH
- **Multilingual blog** – English original plus German, French and Spanish via the free Polylang
  plugin (installed in the admin, not by the playbook); the mu-plugin `language-links.php`
  (`blog_wordpress`) adds an "Also available in" line to posts and pages. The translations are
  content in the WordPress database, created by the author with Claude in a separate workflow –
  **they are not part of this repository**, so a fork has to produce its own translations
- **Anonymous visitor statistics** (`blog_visitor_stats`) – a daily count of visitors, page views,
  countries (local DB-IP Lite lookup) and search-engine arrivals from the access logs; only the totals
  are stored, no IPs, no cookies, no tracker
- **Container health probes** – startup + readiness + liveness (tcpSocket) on
  every FPM, nginx and Collabora container (the blog's MariaDB pod: exec ping with
  a startup gate and 5 s timeouts since 2026-10-20), so a *wedged* (not crashed) container
  is restarted automatically while a slow `occ upgrade` or preview burst never
  trips a restart loop
- **Reproducible app layout** – playbook-driven enable/disable reconcile
  (`nextcloud_apps_enabled` / `_disabled`) that tolerates apps with no version
  compatible with the running major (they simply stay disabled)
- **notify_push (High Performance Backend)** – WebSocket push that replaces the
  ~30 s polling of desktop sync clients and the web UI (phone notifications are
  unrelated, they go through Nextcloud's push proxy). Runs as its own Deployment
  behind a `/push/` ingress route; off by default, enabled per host via
  `nextcloud_notify_push_enabled` (live on the production Nextcloud host,
  `occ notify_push:self-test` 6/6)
- **Pre-flight version check** (`common_version_check`) shows installed vs. latest versions
- **Ansible pipelining**, SSH ControlPersist 600 s, host key checking (accept-new), updates host by host (`serial: 1`)

### Performance

| Feature | Where | Effect |
|---|---|---|
| **HTTP/2** | nginx-ingress | Multiplexing, HPACK header compression |
| **gzip compression** | nginx-ingress | Level 6 for HTML, CSS, JS, JSON, SVG (Brotli is not built into the F5 controller image) |
| **Browser cache** | nginx sidecar (blog) | CSS/JS/fonts 1 year `immutable`, images 30 days, one `Cache-Control` header |
| **Font preload + eager LCP image** | WordPress mu-plugin `performance-hints.php` | No layout shift from font swaps; the first large image loads at once |
| **Uploads as WebP, max 1536 px, < 280 KB** | WordPress mu-plugin `upload-images.php` (`blog_wordpress/tasks/media.yml`) | One image format; featured images small enough for link previews (WhatsApp ignores og:image > ~300 KB) |
| **Redis Object Cache** | WordPress pod | DB queries replaced by Redis lookups |
| **PHP OPcache** | PHP-FPM | Bytecode cached in memory |
| **/tmp on RAM (tmpfs)** | WordPress / Nextcloud FPM | emptyDir – PHP temp files bypass disk |
| **TCP BBR** | Host kernel | Better throughput on congested links |
| **THP madvise** | Host kernel | Prevents latency spikes in MariaDB, Redis |
| `tcp_max_syn_backlog=4096` | Host kernel | Avoids SYN drops under burst traffic |

### Security

#### Firewall – nftables

- `table inet` ruleset covering IPv4 and IPv6 in one ruleset
- Default **DROP policy** on INPUT and FORWARD
- Whitelist-only: SSH (port 10022), HTTP (80), HTTPS (443), ICMP rate-limited
- `banned4` / `banned6` nftables sets with native timeout (filled by Fail2Ban)
- **Port-scan ban** in the kernel: a source that keeps knocking on closed ports
  lands in `scanban4` / `scanban6` and is dropped on *all* ports for a while.
  Fail2Ban can't do this, because it only sees logs and the drop log is
  deliberately rate-limited
- **Reload touches only `table inet filter`**: the ruleset replaces its own
  table atomically, and a systemd drop-in scopes `reload`/`stop` the same way.
  kube-proxy, flannel and K3s's policy controller keep their rules in nftables
  too (iptables-nft on all hosts; the blog used iptables-legacy until 2026-10-19),
  and the stock `flush ruleset` wiped them, breaking Service traffic for up to
  90 s on every firewall change
- The template is checked with `nft -c` before it replaces the live file
- **Optional SSH country filter** (`fw_ssh_geo_countries`, e.g. `[DE]`, off by
  default; on for the blog and cvjm, not sofie): port 10022 accepts new connections
  only from the IP blocks RIPE has delegated to those countries. Web traffic is
  not affected. `ssh-geo-update` builds `/etc/nftables/ssh-geo.nft`, which the
  ruleset includes, so reloads and boots refill the sets in the same
  transaction; a weekly timer refreshes the list and keeps the old one on any
  error (failed download, stale data, a list shrinking by more than 20 %).
  For Germany: ~8,700 IPv4 + 3,100 IPv6 blocks, ~1.5 MB kernel memory. Details
  and the emergency path: [`roles/common_firewall/readme.md`](roles/common_firewall/readme.md)

#### NetworkPolicy – K3s's policy controller (both stacks)

- Enforced by the **network policy controller built into K3s** (kube-router,
  chains `KUBE-ROUTER`/`KUBE-NWPLCY`), which runs by default next to Flannel.
  Never set `disable-network-policy` – nothing else enforces the policies.
- **Calico was removed on 2026-10-19:** it ran in "policy-only" mode since
  August, but Felix only matches pod interfaces named `cali*` (created by
  Calico's own CNI plugin); K3s's Flannel names them `veth*`, so none of its
  rules ever matched a pod. Verified: with K3s's controller disabled a pod in
  `default` reached MariaDB:3306, with it enabled the connection is blocked,
  with or without Calico. `common_calico` now only removes Calico's leftovers.
- `collabora-netpol` restricts the Collabora pod to DNS + the Nextcloud pod
  only – it can no longer reach MariaDB or Redis by any path, direct or via
  the host IP, even though it previously could (verified live both ways).
- Since 2026-10-20 `nextcloud-netpol` (ingress only: ingress controller,
  Collabora's WOPI calls, exporter scrape – egress stays open because the app
  store, push servers, federation and external storages cannot be listed
  without FQDN rules) and `notify-push-netpol` (both directions: ingress
  controller in; DNS and the host's MariaDB/Redis/443 out).
- On the blog, the WordPress stack's policies let only the WordPress pods reach
  MariaDB and Redis, and cap WordPress's own traffic to what it needs
  (`roles/blog_k3s_deploy/templates/networkpolicy.yml.j2`).

#### Intrusion Detection – Fail2Ban

| Jail | Trigger | Ban |
|---|---|---|
| `sshd` | Failed SSH login (3× / 10 min) | 1 h |
| `nginx-k3s-wp-login` | POST `/wp-login.php` (10× / 10 min) | 1 h |
| `nginx-k3s-scanner` | 403/404 storm (20× / 60 s) | 1 h |
| `nginx-k3s-bad-paths` | Known-malicious paths | 24 h |
| `recidive` | Banned 3× in one day | **30 days** |

The HTTP jails read the ingress controller's container log. fail2ban expands
that log path only when a jail starts, but every container restart (and every
reboot, where fail2ban comes up first) creates a new log file. A 2-minute timer
(`fail2ban-ingress-logwatch`) reloads the HTTP jails whenever that happens.
Without it they silently kept watching a dead file.

#### TLS / HTTPS

| Setting | Value |
|---|---|
| Protocols | TLS 1.2 + 1.3 only |
| Key exchange | ECDHE only; hybrid post-quantum `X25519MLKEM768` offered first (OpenSSL 3.5 default) |
| OCSP Stapling | off on purpose – Let's Encrypt retired OCSP; revocation works via CRLs and short lifetimes |
| `ssl_session_tickets` | off (Perfect Forward Secrecy) |
| HSTS | `max-age=31536000; includeSubDomains; preload`, also on the blog's apex redirect (preload-ready) |
| Certificates | Let's Encrypt via cert-manager (HTTP-01), ECDSA P-256 |
| Before issuance | Self-signed placeholder, so a host is never served a bare TLS reset |

Certificates are watched by Monit and alert well before expiry. Until
cert-manager has issued the real one, a short-lived self-signed placeholder is
seeded for each hostname: this ingress controller otherwise answers a host
whose secret does not exist yet with `ssl_reject_handshake`, which is
indistinguishable from "server down" and hides the actual cause (wrong DNS, a
blocked ACME solver, …). cert-manager overwrites the placeholder as soon as
issuance succeeds.

#### System Hardening

- **SELinux enforcing**
- **Container hardening** – dropped Linux capabilities (`drop: [ALL]` + only the
  few each image needs), `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation:
  false`, and **read-only root filesystems** on the nginx/exporter sidecars
- **auditd** with security-relevant rules
- **rkhunter** daily scan with email alerts
- **ClamAV** nightly scan of Nextcloud user data / WordPress uploads, email alerts; on the Nextcloud
  hosts the scan skips Nextcloud previews and pure image/video/audio files (`clamav_skip_extensions`)
- **dnf-automatic** for auto security updates, automatic reboot if required.
  The night runs in a fixed order: AIDE check 00:00, updates 01:00-02:00,
  reboot if needed 03:30, AIDE baseline refresh 04:00, ClamAV data scan 04:30
  (Nextcloud hosts) - so an update never triggers a false AIDE alert and a
  reboot never cuts a scan short
- **systemd hardening** drop-ins for sshd, node_exporter, prometheus
- **CIS AlmaLinux 9 Benchmark** hardening (AIDE file integrity, kernel module
  blacklist, cron/sudo permissions, `nodev,nosuid,noexec` mount options)
- **Monit watchdog** with email alerts on resource, service, firewall and K3s
  pod problems – including **TLS certificate expiry**, so a silently failing
  cert-manager renewal is noticed weeks before the site would go dark

---

## Requirements

### Control node (your machine)
- ansible-core 2.16+ (tested with 2.19), Python 3.10+
- Collections with exact versions from `requirements.yml` (`community.mysql`, `ansible.posix`,
  `community.general`, `kubernetes.core` >= 6.5.0 for Helm 4):
  `ansible-galaxy collection install -r requirements.yml`
- Optional, for the checks and tests: `pre-commit`, `ansible-lint`, podman

### Internet servers (AlmaLinux 9)
- Fresh AlmaLinux 9 install
- Why not AlmaLinux 10 (available since May 2025)? 9 is proven, its ecosystem (EPEL, SELinux policy for K3s, CIS benchmark, MariaDB repos) is mature, and it gets security updates until May 2032. The move to 10 comes later as a fresh server set up by the playbook, once the roles are tested against it.
- Min. 4 GB RAM (8 GB recommended with Collabora)
- Public IPv4 with DNS A-records
- SSH root access on port 22 (switches to 10022 after first run)

---

## Quick Start

```bash
git clone https://github.com/aptupgrademe/www_k3s.git
cd www_k3s

# Set up inventory
cp inventory/host_vars/test/vars.yml.example inventory/host_vars/myserver/vars.yml
cp inventory/host_vars/test/vault.yml.example inventory/host_vars/myserver/vault.yml
# Fill in passwords, then encrypt:
ansible-vault encrypt inventory/host_vars/myserver/vault.yml

# Deploy Nextcloud
ansible-playbook nextcloud-k3s.yml --limit myserver --ask-vault-pass

# Deploy WordPress
ansible-playbook blog.yml --limit myserver --ask-vault-pass
```

### First run on a fresh server

A fresh server still has SSH on port 22, while these playbooks move it to
10022 and switch on the nftables firewall. Set `ansible_port: 22` in the
host's `vars.yml` for the very first run.

The playbook handles the switchover itself: it writes the new SSH config and
firewall ruleset but activates neither mid-run, then reboots once so both come
up together from a clean boot and reconnects on the new port. (Activating them
live instead would kill the connection Ansible is using – the firewall has no
conntrack entry for a session that predates it, so the run just hangs.)

Afterwards, change `ansible_port` from `22` to `10022` in that same
`vars.yml`. This is the one manual step that cannot be automated away: Ansible
reads the port from the inventory *before* it connects, so the next separate
run has no other way to know where to reach the server. The playbook prints a
reminder at the end of a first run.

---

## Project Structure

```
www_k3s/
├── nextcloud-k3s.yml          # Nextcloud + Collabora playbook
├── blog.yml                   # WordPress playbook
├── nextcloud-update.yml       # Nextcloud patch update playbook
├── blog-update.yml            # WordPress plugins/themes/core + rebuilt images, on demand
│
├── inventory/
│   ├── hosts.yml              # Server inventory (gitignored)
│   ├── group_vars/all/
│   │   ├── main.yml           # Shared settings: CIDRs, HostPath dirs, resource defaults
│   │   └── versions.yml       # ALL version pins in one place (Renovate keeps them current)
│   └── host_vars/<host>/
│       ├── vars.yml           # Host-specific config – gitignored
│       ├── vault.yml          # Encrypted secrets – gitignored, NEVER committed
│       └── vault.yml.example  # Template with placeholder values (committed)
│
├── roles/
│   ├── common_*/              # Shared roles (K3s, SSH, Firewall, Monitoring, ClamAV, SELinux, …)
│   ├── next_*/                # Nextcloud-specific roles
│   └── blog_*/                # WordPress-specific roles
│
├── scripts/
│   ├── nextcloud-backup/      # Pull backup (rsync + rdiff-backup) for a backup machine, see its README
│   ├── nextcloud-restore.sh   # Nextcloud restore from /data/backup/nextcloud-data/<env>
│   ├── wordpress-backup/      # Pull backup (rsync + rdiff-backup) for the blog, see its README
│   ├── wordpress-backup.sh    # Manual ad-hoc WordPress backup via kubectl exec
│   ├── wordpress-restore.sh   # WordPress restore including MariaDB re-init
│   └── check-drift.sh         # --check --diff against a host: what would a real run change?
│
├── tests/
│   ├── k8s/                   # Kubernetes roles against a throwaway API-only K3s in podman
│   └── update/                # Failure scenarios of the update playbooks (fake kubectl/crictl)
│
├── .ansible-lint, .yamllint, .pre-commit-config.yaml, .github/workflows/lint.yml, renovate.json5
│
└── docs/
    ├── wordpress-betrieb.html       # WordPress – Betriebsdokumentation (DE)
    ├── wordpress-operations.html    # WordPress – Operations guide (EN)
    ├── wordpress-exploitation.html  # WordPress – Guide d'exploitation (FR)
    ├── nextcloud-betrieb.html       # Nextcloud – Betriebsdokumentation (DE)
    ├── nextcloud-operations.html    # Nextcloud – Operations guide (EN)
    ├── nextcloud-exploitation.html  # Nextcloud – Guide d'exploitation (FR)
    ├── ansible-funktionsweise.html  # Ansible code – how it works (DE)
    ├── ansible-internals.html       # Ansible code – how it works (EN)
    └── ansible-fonctionnement.html  # Ansible code – how it works (FR)
```

---

## Secrets Management

Credentials are **never committed** to this repository. The `.gitignore` excludes:
- `inventory/hosts.yml`
- `inventory/host_vars/*/vars.yml`
- `inventory/host_vars/*/vault.yml`
- `.vault_pass`

Only `vault.yml.example` templates with placeholder values are tracked in Git.

```bash
cp inventory/host_vars/<host>/vault.yml.example \
   inventory/host_vars/<host>/vault.yml
# Fill in real values, then encrypt:
ansible-vault encrypt inventory/host_vars/<host>/vault.yml
```

---

## Roles Overview

### Common

| Role | Purpose |
|---|---|
| `common_sysctl` | Kernel tuning: TCP BBR, backlog=4096, THP madvise |
| `common_msmtp` | SMTP relay for system notifications |
| `common_dnf_automatic` | Automatic security updates on AlmaLinux |
| `common_logrotate` | Log rotation for Grafana, fail2ban, rkhunter |
| `common_version_check` | Pre-flight: K3s, Helm, chart and image versions vs. latest |
| `common_version_active` | Last check: is every pin from versions.yml really running (kubelet, deployed charts, images of running containers, Prometheus/exporters, pending reboot, services on old code)? Reports only what is not active |
| `common_k3s` | K3s, Helm, cert-manager, F5 nginx-ingress (HTTP/2, Brotli, OCSP) |
| `common_calico` | Removes Calico (it never enforced anything here, see NetworkPolicy above); deleted once no host has it |
| `common_kube_metrics` | Container metrics: read-only scraper token for the kubelet's cAdvisor + kube-state-metrics (NodePort 30808, local only) |
| `common_firewall` | nftables only (legacy iptables packages removed; `common_cis_hardening` blocks the legacy table modules) – table inet, banned/scan-ban sets, port-scan detection, K3s exceptions, table-scoped reload, optional SSH country allowlist; on the blog the same list also limits `/wp-login.php` + `/wp-admin/` (nginx geo file, since 2026-10-19), and on every host `/grafana` in the ingress controller (`/srv/ingress-admin-geo`, since 2026-10-20) |
| `common_ssh` | SSH hardening (port 10022, key-only, PermitRootLogin without-password) |
| `common_prometheus` | Prometheus metrics collector (dashboards/history only – see note below) |
| `common_grafana` | Grafana dashboards (incl. our own "Container-Ressourcen") |
| `common_loki` | Loki + Grafana Alloy: journal, pod logs, audit.log/fail2ban.log (14 days, 127.0.0.1 only), Loki datasource + log alerts (AVC, fail2ban error, OOM, no logs) – all hosts since 2026-10-20 (blog 2026-10-19) |
| `common_node_exporter` | Host metrics exporter (+ textfile collector in `/var/lib/node_exporter/textfile`, fed by `common_trivy`) |
| `common_mysqld_exporter` | MariaDB metrics exporter |
| `common_monit` | Watchdog (systemd-sandboxed since 2026-10-19) and **the actual alerting path** – e-mails on resource/service/firewall/pod/TLS-certificate problems (since 2026-10-20 also the host MariaDB and Redis of the Nextcloud stack), auto-restarts fail2ban |
| `common_fail2ban` | Brute-force protection; writes to nftables banned sets; log-watch timer keeps the HTTP jails on the current ingress log |
| `common_auditd` | Linux audit daemon |
| `common_rkhunter` | Rootkit detection with daily scan |
| `common_cis_hardening` | CIS AlmaLinux 9 Benchmark: AIDE, kernel modules, cron/sudo, mount options |
| `common_aide_refresh` | Refreshes the AIDE baseline after approved changes, so the nightly check isn't a false alarm |
| `common_clamav` | Nightly ClamAV scan – WordPress uploads or Nextcloud data (`clamav_target`) |
| `common_trivy` | Nightly Trivy scan (pinned version + sha256) of every running image from containerd; counts in Grafana via the node_exporter textfile collector, mail only on NEW fixable CRITICAL/HIGH findings – all hosts since 2026-10-20 (blog 2026-10-19) |
| `common_selinux` | SELinux enforcing + `container_file_t` for the stack's HostPath dirs (`selinux_target`); the pods run as `container_t` since `common_k3s` sets `selinux: true` with the `k3s-selinux` policy (2026-10-19) |
| `common_selinux_monitoring` | Own SELinux domains (`homelab_*` modules) for Prometheus, node_exporter, mysqld_exporter and Grafana – permissive learning phase since 2026-10-19, enforcing after review |
| `common_verify` | Smoke checks shared by `blog_verify` and `nextcloud_verify` |
| `common_image_refresh` | Update playbooks: which Deployments run an outdated build of their tag |

> **Alerting:** Monit is the main mail path. Prometheus evaluates the rules in
> `alert.rules.yml`, but no Alertmanager is deployed, so a firing rule is only
> visible in its web UI. That is deliberate for a single-node setup: Monit
> already covers the same ground (load, memory, disk, services, firewall, K3s
> pods, TLS expiry) and mails about it. Grafana adds nine mail alerts of its own
> (disk root/data, RAM, CPU, node down; per container: memory near the limit,
> CPU throttling, OOM kill, restart loop) via the `email-admin` contact point. Each rule
> needs `"condition": "B"`; without it Grafana logs "condition must not be
> empty" on every evaluation and never fires.

### Nextcloud & WordPress

| Role | Purpose |
|---|---|
| `next_*` | Nextcloud + Collabora roles |
| `blog_*` | WordPress + Redis Object Cache roles (login/admin only from the SSH country list, see `common_firewall`) |

---

## Updating Component Versions

All pinned versions live in one file, [`inventory/group_vars/all/versions.yml`](inventory/group_vars/all/versions.yml)
– values on top, reasons and history below. Renovate (`renovate.json5`) proposes bumps as pull requests (majors and
K3s minors only after approval); the `common_version_check` role also compares them against the latest releases
at every playbook run. Before rolling a bump out: `scripts/check-drift.sh <playbook> <host>`.

```yaml
# Helm charts
ingress_nginx_chart_version: "2.8.0"
cert_manager_chart_version:  "1.21.2"

# Container images
blog_image_wordpress: "wordpress:7.1.3-php8.4-fpm"
nextcloud_image_fpm:  "nextcloud:34.0.5-fpm"

```

(`calico_version` and `scripts/calico-derive-manifest.py` only remain so `common_calico` can name the objects it
deletes; both go away together with that role.)

---

## Code Quality & Tests

| What | How |
|---|---|
| Lint | `ansible-lint`, `yamllint` – config in `.ansible-lint`, `.ansible-lint-ignore`, `.yamllint` |
| Secret scan | `gitleaks` on every commit (pre-commit) and over the full history on GitHub |
| Hooks | `pre-commit install` once per clone; `pre-commit run --all-files` |
| CI | `.github/workflows/lint.yml` – ansible-lint + gitleaks on every push |
| K8s roles | `tests/k8s/run.sh` – idempotency, no pod restarts, no new Helm revisions, negative test |
| Update playbooks | `tests/update/run.sh` – 14 failure scenarios (rescue, maintenance mode, pre-flight) |
| Real hosts | `scripts/check-drift.sh <playbook> <host>` – exit 1 if a real run would change anything |

How the code works – variables, roles, idempotency, Kubernetes modules, error handling, tests:
[docs/ansible-internals.html](docs/ansible-internals.html) (EN),
[docs/ansible-funktionsweise.html](docs/ansible-funktionsweise.html) (DE),
[docs/ansible-fonctionnement.html](docs/ansible-fonctionnement.html) (FR).

---

## Documentation

| Document | WordPress | Nextcloud |
|---|---|---|
| **Deutsch** | [wordpress-betrieb.html](docs/wordpress-betrieb.html) | [nextcloud-betrieb.html](docs/nextcloud-betrieb.html) |
| **English** | [wordpress-operations.html](docs/wordpress-operations.html) | [nextcloud-operations.html](docs/nextcloud-operations.html) |
| **Français** | [wordpress-exploitation.html](docs/wordpress-exploitation.html) | [nextcloud-exploitation.html](docs/nextcloud-exploitation.html) |

| Ansible code (how it works) | |
|---|---|
| **Deutsch** | [ansible-funktionsweise.html](docs/ansible-funktionsweise.html) |
| **English** | [ansible-internals.html](docs/ansible-internals.html) |
| **Français** | [ansible-fonctionnement.html](docs/ansible-fonctionnement.html) |

Each guide covers: architecture, configuration, playbook execution,
security, performance and troubleshooting.

---

## License

MIT License – see [LICENSE](LICENSE) for details.

You are free to use, modify and distribute this code. Please retain the copyright
notice and attribution to the original author.
