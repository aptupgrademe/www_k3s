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
│  │  Calico policy-only (Nextcloud – NetworkPolicy)    │    │
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
- **Calico (policy-only mode)** – NetworkPolicy enforcement for Nextcloud;
  Collabora is restricted from ever reaching MariaDB/Redis directly, since
  K3s's default Flannel CNI does not enforce NetworkPolicy objects at all
- **WordPress 7.1.1** with PHP-FPM, nginx sidecar, MariaDB pod and **Redis Object Cache** pod
- Automatic installation on first pod start via container env vars and WP-CLI
- WordPress WP-Cron as Kubernetes CronJob (no HTTP trigger)
- **Container health probes** – startup + readiness + liveness (tcpSocket) on
  every FPM, nginx and Collabora container, so a *wedged* (not crashed) container
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
- **Ansible pipelining**, fact caching (1 h), SSH ControlPersist 600 s

### Performance

| Feature | Where | Effect |
|---|---|---|
| **HTTP/2** | nginx-ingress | Multiplexing, HPACK header compression |
| **Brotli compression** | nginx-ingress | 15–25% smaller responses vs. gzip |
| **OCSP Stapling** | nginx-ingress | Saves one CA round-trip per TLS handshake |
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
  kube-proxy, flannel and Calico keep their rules in nftables too (iptables-nft),
  and the stock `flush ruleset` wiped them, breaking Service traffic for up to
  90 s on every firewall change
- The template is checked with `nft -c` before it replaces the live file

#### NetworkPolicy – Calico (Nextcloud)

- Installed in **policy-only mode**: only Felix + kube-controllers run,
  reading Pods/NetworkPolicy objects from the Kubernetes API. Flannel keeps
  doing all pod networking/IPAM/CNI plugin duties unchanged.
- `collabora-netpol` restricts the Collabora pod to DNS + the Nextcloud pod
  only – it can no longer reach MariaDB or Redis by any path, direct or via
  the host IP, even though it previously could (verified live both ways).

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
| OCSP Stapling | on (resolver 1.1.1.1/8.8.8.8) |
| `ssl_session_tickets` | off (Perfect Forward Secrecy) |
| HSTS | `max-age=31536000; includeSubDomains; preload` |
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
- **ClamAV** nightly scan of Nextcloud user data / WordPress uploads, email alerts
- **dnf-automatic** for auto security updates, automatic reboot if required
- **systemd hardening** drop-ins for sshd, node_exporter, prometheus
- **CIS AlmaLinux 9 Benchmark** hardening (AIDE file integrity, kernel module
  blacklist, cron/sudo permissions, `nodev,nosuid,noexec` mount options)
- **Monit watchdog** with email alerts on resource, service, firewall and K3s
  pod problems – including **TLS certificate expiry**, so a silently failing
  cert-manager renewal is noticed weeks before the site would go dark

---

## Requirements

### Control node (your machine)
- Ansible 2.15+
- Python 3.8+
- `community.mysql` and `ansible.posix` collections

### Internet servers (AlmaLinux 9)
- Fresh AlmaLinux 9 install
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
│
├── inventory/
│   ├── hosts.yml              # Server inventory (gitignored)
│   ├── group_vars/all.yml     # Shared variables: image versions, chart versions
│   └── host_vars/<host>/
│       ├── vars.yml           # Host-specific config – gitignored
│       ├── vault.yml          # Encrypted secrets – gitignored, NEVER committed
│       └── vault.yml.example  # Template with placeholder values (committed)
│
├── roles/
│   ├── common_*/              # Shared roles (K3s, SSH, Firewall, Monitoring, Calico, …)
│   ├── next_*/                # Nextcloud-specific roles
│   └── blog_*/                # WordPress-specific roles
│
├── scripts/
│   ├── nextcloud-backup.sh    # Nextcloud backup: nextcloud-backup.sh <env>
│   ├── nextcloud-restore.sh   # Nextcloud restore
│   ├── wordpress-backup.sh    # WordPress backup via kubectl exec
│   └── wordpress-restore.sh   # WordPress restore including MariaDB re-init
│
└── docs/
    ├── wordpress-betrieb.html       # WordPress – Betriebsdokumentation (DE)
    ├── wordpress-operations.html    # WordPress – Operations guide (EN)
    ├── wordpress-exploitation.html  # WordPress – Guide d'exploitation (FR)
    ├── nextcloud-betrieb.html       # Nextcloud – Betriebsdokumentation (DE)
    ├── nextcloud-operations.html    # Nextcloud – Operations guide (EN)
    └── nextcloud-exploitation.html  # Nextcloud – Guide d'exploitation (FR)
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
| `common_k3s` | K3s, Helm, cert-manager, F5 nginx-ingress (HTTP/2, Brotli, OCSP) |
| `common_calico` | Calico policy-only mode: NetworkPolicy enforcement (Nextcloud) |
| `common_firewall` | nftables (table inet, banned/scan-ban sets, port-scan detection, K3s exceptions, table-scoped reload) |
| `common_ssh` | SSH hardening (port 10022, key-only, PermitRootLogin without-password) |
| `common_prometheus` | Prometheus metrics collector (dashboards/history only – see note below) |
| `common_grafana` | Grafana dashboards |
| `common_node_exporter` | Host metrics exporter |
| `common_mysqld_exporter` | MariaDB metrics exporter |
| `common_monit` | Watchdog and **the actual alerting path** – e-mails on resource/service/firewall/pod/TLS-certificate problems, auto-restarts fail2ban |
| `common_fail2ban` | Brute-force protection; writes to nftables banned sets; log-watch timer keeps the HTTP jails on the current ingress log |
| `common_auditd` | Linux audit daemon |
| `common_rkhunter` | Rootkit detection with daily scan |
| `common_cis_hardening` | CIS AlmaLinux 9 Benchmark: AIDE, kernel modules, cron/sudo, mount options |
| `common_aide_refresh` | Refreshes the AIDE baseline after approved changes, so the nightly check isn't a false alarm |

> **Alerting:** Monit is the main mail path. Prometheus evaluates the rules in
> `alert.rules.yml`, but no Alertmanager is deployed, so a firing rule is only
> visible in its web UI. That is deliberate for a single-node setup: Monit
> already covers the same ground (load, memory, disk, services, firewall, K3s
> pods, TLS expiry) and mails about it. Grafana adds five mail alerts of its own
> (disk, RAM, CPU, node down) via the `email-admin` contact point. Each rule
> needs `"condition": "B"`; without it Grafana logs "condition must not be
> empty" on every evaluation and never fires.

### Nextcloud & WordPress

| Role | Purpose |
|---|---|
| `next_*` | Nextcloud + Collabora roles |
| `blog_*` | WordPress + Redis Object Cache roles |

---

## Updating Component Versions

All pinned versions live in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml).
The `common_version_check` role compares them against latest releases at every playbook run.

```yaml
# Helm charts
ingress_nginx_chart_version: "2.6.4"
cert_manager_chart_version:  "1.21.1"

# Container images
blog_image_wordpress: "wordpress:7.1.0-php8.4-fpm"
nextcloud_image_fpm:  "nextcloud:34.0.3-fpm"

# Calico (Nextcloud policy-only NetworkPolicy enforcement)
calico_version: "v3.32.1"
```

---

## Documentation

| Document | WordPress | Nextcloud |
|---|---|---|
| **Deutsch** | [wordpress-betrieb.html](docs/wordpress-betrieb.html) | [nextcloud-betrieb.html](docs/nextcloud-betrieb.html) |
| **English** | [wordpress-operations.html](docs/wordpress-operations.html) | [nextcloud-operations.html](docs/nextcloud-operations.html) |
| **Français** | [wordpress-exploitation.html](docs/wordpress-exploitation.html) | [nextcloud-exploitation.html](docs/nextcloud-exploitation.html) |

Each guide covers: architecture, configuration, playbook execution,
security, performance and troubleshooting.

---

## License

MIT License – see [LICENSE](LICENSE) for details.

You are free to use, modify and distribute this code. Please retain the copyright
notice and attribution to the original author.
