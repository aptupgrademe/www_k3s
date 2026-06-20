# K3s Homelab – Nextcloud & WordPress

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Ansible](https://img.shields.io/badge/Ansible-2.15+-red.svg)](https://www.ansible.com/)
[![K3s](https://img.shields.io/badge/K3s-latest-blue.svg)](https://k3s.io/)
[![AlmaLinux](https://img.shields.io/badge/AlmaLinux-9-green.svg)](https://almalinux.org/)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-34-0082C9.svg)](https://nextcloud.com/)
[![WordPress](https://img.shields.io/badge/WordPress-7.0-21759B.svg)](https://wordpress.org/)

Ansible playbooks for deploying a fully automated, production-ready homelab on a
single AlmaLinux 9 server using K3s (lightweight Kubernetes).

Supports two independent deployment scenarios:

| Scenario | Playbook | What gets deployed |
|---|---|---|
| **Nextcloud** | `nextcloud-k3s.yml` | Nextcloud + Collabora CODE (online office) |
| **WordPress** | `blog.yml` | WordPress blog |

Both scenarios share a common infrastructure layer (K3s, nginx-ingress, cert-manager,
Prometheus, Grafana, Fail2Ban, nftables hardening).

---

## Architecture

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
│  │  nginx-ingress  (F5, hostNetwork, ports 80/443)    │    │  ← TLS, rate-limiting, Brotli
│  │  cert-manager   (Let's Encrypt – auto TLS)         │    │
│  │                                                     │    │
│  │  ┌──────────────────┐  ┌─────────────────────────┐ │    │
│  │  │  Nextcloud stack │  │   WordPress stack        │ │    │
│  │  │  nextcloud-fpm   │  │   wordpress-fpm          │ │    │
│  │  │  nginx sidecar   │  │   nginx sidecar          │ │    │
│  │  │  Collabora CODE  │  │   MariaDB pod            │ │    │
│  │  └──────────────────┘  │   Redis pod  (new)       │ │    │
│  │                        └─────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  Host services (Nextcloud scenario):                        │
│  MariaDB · Redis · Node Exporter · mysqld_exporter          │
│                                                             │
│  Host services (both scenarios):                            │
│  Prometheus · Grafana · Fail2Ban · nftables                 │
│  auditd · rkhunter · dnf-automatic · msmtp                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

### Application

- **Nextcloud 34** with PHP-FPM, nginx sidecar, Redis (host service) and MariaDB 10.11
- **Collabora CODE** (online office) with WOPI integration
- **WordPress 7.0** with PHP-FPM, nginx sidecar, MariaDB pod and **Redis Object Cache** pod
- Automatic installation on first pod start via container env vars and WP-CLI
- WordPress WP-Cron as Kubernetes CronJob (no HTTP trigger)
- Redis Object Cache plugin (`redis-cache`) pre-installed and activated for WordPress

### Infrastructure

- **K3s** single-node Kubernetes (Flannel/VXLAN CNI)
- **F5 nginx-ingress** (nginx-stable Helm chart) with hostNetwork and DaemonSet
- **cert-manager** for automatic Let's Encrypt TLS certificates (HTTP-01 challenge)
- Kubernetes Secrets for all credentials (Ansible Vault encrypted locally)
- **Pre-flight version check** (`common_version_check`) at playbook start:
  shows installed vs. latest K3s, Helm, Helm chart and container image versions
- **Ansible pipelining** enabled (eliminates SSH round-trips, ~40% faster runs)
- **Fact caching** (1 h JSON cache in `/tmp/ansible_facts_cache`)
- **SSH ControlPersist 600 s** for long playbook runs
- **Profile tasks** callback shows per-task timing at end of each run

### Performance

| Feature | Where | Effect |
|---|---|---|
| **Brotli compression** | nginx-ingress | 15–25% smaller responses vs. gzip for text/JS/CSS |
| **gzip compression** | nginx-ingress | Fallback for browsers without Brotli support |
| **OCSP Stapling** | nginx-ingress | Saves one CA round-trip per TLS handshake (~50–100 ms) |
| **TLS session cache** | nginx-ingress | `shared:SSL:10m` – reuses negotiated sessions |
| **Redis Object Cache** | WordPress pod | DB queries for cached objects reduced to Redis lookups |
| **PHP OPcache** | PHP-FPM | Compiled bytecode cached in memory, no repeated parsing |
| **/tmp on RAM (tmpfs)** | WordPress FPM | 64 Mi emptyDir(Memory) – PHP temp files bypass disk I/O |
| **TCP BBR** | Host kernel | Better throughput and fairness on congested links |
| **TCP Fast Open** | Host kernel | Reduces latency for returning connections |
| **MariaDB tuning** | MariaDB pod / host | InnoDB buffer pool, query cache tuning |
| **php-fpm workers** | WordPress / Nextcloud | Optimised `pm.max_children` for available RAM |

### Security

#### Firewall – nftables

- `table inet` ruleset covering **IPv4 and IPv6 in one ruleset**
- Default **DROP policy** on INPUT and FORWARD
- Whitelist-only: SSH (port 10022), HTTP (80), HTTPS (443), ICMP (rate-limited)
- **Port-scan detection**: TCP packets to closed ports trigger a 60-second ban
- **K3s mandatory exceptions**: pod→API server (6443), kubelet (10250), OUTPUT to pod CIDR (10.42.0.0/16) for liveness probes
- `banned4` / `banned6` nftables **sets with native timeout** (IPs expire automatically, no cron needed)
- Active config at `/etc/sysconfig/nftables.conf` (AlmaLinux default, loaded by systemd)

#### Intrusion Detection – Fail2Ban

Five active jails, all writing directly to `banned4`/`banned6` nftables sets:

| Jail | Trigger | Threshold | Ban |
|---|---|---|---|
| `sshd` | Failed SSH login | 3 attempts / 10 min | 1 h |
| `nginx-k3s-wp-login` | POST `/wp-login.php` | 10 attempts / 10 min | 1 h |
| `nginx-k3s-scanner` | 403/404 responses | 20 hits / 60 s | 1 h |
| `nginx-k3s-bad-paths` | Known-malicious paths (`.env`, webshells, phpMyAdmin …) | 2 hits / 1 h | 24 h |
| `recidive` | Banned 3× in one day | 3 bans / 24 h | **30 days** |

- **Self-ban prevention**: all Ansible smoke-test requests that could trigger jails (`.env`, `xmlrpc.php`, `readme.html`, REST API) are made via `curl --resolve hostname:443:127.0.0.1` on the server — source IP is `127.0.0.1`, which is in `ignoreip`
- `ignoreip` covers `127.0.0.1/8`, `::1`, and all RFC-1918 ranges
- HTTP jails parse containerd-prefixed access logs (`/var/log/pods/ingress-nginx_ingress-nginx-*/nginx-ingress/0.log`) using custom filter definitions (`filter.d/nginx-k3s-*.conf`)

#### TLS / HTTPS

All TLS settings are applied globally via the nginx-ingress Helm ConfigMap:

| Setting | Value | Reason |
|---|---|---|
| `ssl-protocols` | `TLSv1.2 TLSv1.3` | Disable SSLv3, TLS 1.0, TLS 1.1 |
| `ssl-ciphers` | ECDHE+GCM, ECDHE+ChaCha20 only | No RSA key exchange, no CBC ciphers |
| `ssl-prefer-server-ciphers` | `false` | TLS 1.3: client chooses cipher (RFC 8446) |
| `ssl_session_tickets` | `off` | Forces fresh key derivation → Perfect Forward Secrecy preserved even if ticket key leaks |
| `ssl_session_cache` | `shared:SSL:10m` | Shared across workers, 1-day timeout |
| `ssl_stapling` | `on` | OCSP Stapling enabled |
| `ssl_stapling_verify` | `on` | Verify OCSP responses against CA chain |
| `resolver` | `1.1.1.1 8.8.8.8 valid=60s` | Required for nginx to resolve OCSP responder hostname |
| HSTS header | `max-age=31536000; includeSubDomains; preload` | Forces HTTPS; eligible for browser preload list |

#### HTTP Security Headers

Applied via `nginx.org/location-snippets` on every Ingress:

| Header | Value |
|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains; preload` |
| `X-Frame-Options` | `SAMEORIGIN` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `same-origin` |
| `X-Permitted-Cross-Domain-Policies` | `none` |

#### WordPress Hardening

Blocked at **nginx-ingress level** (via `server-snippets`, before the request reaches the WordPress pod):

| Path | HTTP response | Reason |
|---|---|---|
| `/xmlrpc.php` | 403 | Remote code execution vector, brute-force target |
| `/readme.html` | 403 | Exposes WordPress version |
| `/license.txt` | 403 | Exposes WordPress version |

**Rate-limiting** at ingress level:
- `/wp-login.php`: 5 req/s per IP, burst 5 — proxied to WordPress after rate-check

**WordPress MU-Plugin** (`mu-plugins/security-hardening.php`, always active, no deactivation possible):
- Removes WordPress version from `<meta name="generator">`, RSS feeds and HTTP `Link:` headers
- Removes RSD and Windows Live Writer discovery links from `<head>`
- Hides Yoast SEO version from HTML comments
- **Blocks REST API user enumeration** for unauthenticated requests (`/wp/v2/users` → 404 for guests)
- Blocks `?author=` redirect enumeration

**DISABLE_WP_CRON** set to `true` — cron runs as a K8s CronJob instead of HTTP trigger, eliminating one attack surface and ensuring reliable scheduling.

#### System Hardening

- **SELinux enforcing** with `container_file_t` contexts for all K3s HostPath volumes
- **auditd** with rules covering: sudo usage, SSH key changes, cron modifications, kernel module loading, `/etc/passwd` and `/etc/shadow` changes
- **rkhunter** daily rootkit scan with email alerts via msmtp
- **dnf-automatic** for automatic security-only updates
- SSH: non-default port (10022), key-only authentication, root login permitted only with key, PasswordAuthentication disabled

### Monitoring

- **Prometheus** scraping Node Exporter (host metrics), mysqld_exporter (MariaDB), php-fpm_exporter (FPM process metrics)
- **Grafana** with three pre-imported dashboards:
  - Node Exporter Full (ID 1860) – CPU, RAM, Disk, Network
  - MySQL Overview (ID 7362) – MariaDB queries, InnoDB, slow queries
  - PHP-FPM (ID 4912) – FPM processes, request queue, slow requests
- **Grafana Alerting** with 5 pre-configured alert rules (disk root >80%, data partition >80%, RAM >90%, CPU >85%, Node Exporter unreachable) and email notification via SMTP
- MariaDB slow query log (threshold: 1 second)
- PHP-FPM slow log (threshold: 5 seconds)
- Grafana accessible at `https://<hostname>/grafana/`

### Post-Deployment Smoke Tests

Both scenarios include a colored terminal verification report after every deployment:

**blog_verify** – 26 checks across 5 categories:
- System services (nftables, fail2ban, K3s, auditd, SELinux)
- Kubernetes workloads (pods running, no errors)
- HTTPS (TLS validity, HSTS, Server header, X-Powered-By)
- Security (xmlrpc.php / .env / readme.html blocked, REST API no user leak)
- Performance (TCP BBR, PHP OPcache, MariaDB reachable)

**nextcloud_verify** – 31 checks including Nextcloud-specific checks:
- Nextcloud installed and not in maintenance mode
- Background-job mode is `cron` (not HTTP trigger)
- Redis and MariaDB reachable from Nextcloud pod

All security checks run via `curl --resolve hostname:443:127.0.0.1` on the server (source IP = 127.0.0.1) to prevent triggering fail2ban jails.

---

## Requirements

### Control node (your machine)
- Ansible 2.15+
- Python 3.8+
- `community.mysql` collection: `ansible-galaxy collection install community.mysql`

### Target server
- AlmaLinux 9 (fresh install)
- Min. 4 GB RAM (8 GB recommended when using Collabora)
- Min. 20 GB disk
- Public IPv4 address with DNS A-records pointing to it
- SSH root access on port 22 (switches to 10022 after first run)

### DNS records required
```
# Nextcloud scenario:
nextcloud.example.de  A  <server-ip>
collabora.example.de  A  <server-ip>

# WordPress scenario:
www.example.de  A  <server-ip>
```

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/aptupgrademe/www_k3s.git
cd www_k3s
```

### 2. Set up inventory

Edit `inventory/hosts.yml` and add your server(s):

```yaml
nextcloud:
  hosts:
    myserver:
      ansible_host: "1.2.3.4"
```

Copy and fill in host variables:

```bash
mkdir -p inventory/host_vars/myserver

# Non-secret variables (IPs, hostnames, mail settings)
cp inventory/host_vars/test/vars.yml inventory/host_vars/myserver/vars.yml

# Credentials (passwords, tokens)
cp inventory/host_vars/test/vault.yml.example inventory/host_vars/myserver/vault.yml
# Fill in real passwords, then encrypt:
ansible-vault encrypt inventory/host_vars/myserver/vault.yml
```

### 3. Deploy

```bash
# Nextcloud + Collabora
ansible-playbook nextcloud-k3s.yml --limit myserver --ask-vault-pass

# WordPress blog
ansible-playbook blog.yml --limit myserver --ask-vault-pass
```

After the first run, reboot the server to activate the firewall rules, then update
`ansible_port: 22` → `10022` in `vars.yml`.

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
│   ├── group_vars/all.yml     # Shared variables: image versions, chart versions, CIDRs
│   └── host_vars/<host>/
│       ├── vars.yml           # Host-specific config (IPs, hostnames, SMTP) – gitignored
│       ├── vault.yml          # Secrets – gitignored, NEVER committed
│       └── vault.yml.example  # Template with placeholder values (committed)
│
├── roles/
│   ├── common_*/              # Shared roles (K3s, SSH, Firewall, Monitoring, …)
│   ├── next_*/                # Nextcloud-specific roles
│   └── blog_*/                # WordPress-specific roles
│
├── scripts/
│   ├── nextcloud-backup.sh    # Backup: nextcloud-backup.sh <env>
│   ├── nextcloud-restore.sh   # Restore: nextcloud-restore.sh <env>
│   ├── wordpress-backup.sh    # WordPress backup via kubectl exec
│   └── wordpress-restore.sh   # WordPress restore including MariaDB re-init
│
└── docs/
    ├── wordpress-betrieb.html       # WordPress – Guide d'exploitation (Deutsch)
    ├── wordpress-operations.html    # WordPress – Operations guide (English)
    ├── wordpress-exploitation.html  # WordPress – Guide d'exploitation (Français)
    ├── nextcloud-betrieb.html       # Nextcloud – Betriebsdokumentation (Deutsch)
    ├── nextcloud-operations.html    # Nextcloud – Operations guide (English)
    └── nextcloud-exploitation.html  # Nextcloud – Guide d'exploitation (Français)
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
# Workflow for secrets:
cp inventory/host_vars/<host>/vault.yml.example \
   inventory/host_vars/<host>/vault.yml
# Fill in real values, then encrypt:
ansible-vault encrypt inventory/host_vars/<host>/vault.yml
```

Keep your `vault.yml` files in a **separate private repository** or encrypted backup.
Store the vault password in a password manager, not in this repository.

---

## Roles Overview

| Role | Purpose |
|---|---|
| `common_version_check` | Pre-flight: K3s, Helm, chart and image versions vs. latest |
| `common_k3s` | K3s installation, Helm, cert-manager, F5 nginx-ingress |
| `common_firewall` | nftables hardening (table inet, banned4/banned6 sets, K3s exceptions) |
| `common_ssh` | SSH hardening (custom port 10022, key-only auth) |
| `common_sysctl` | Kernel tuning: TCP BBR, Fast Open, connection timeouts |
| `common_prometheus` | Prometheus metrics collector |
| `common_grafana` | Grafana: pre-imported dashboards, alert rules, SMTP notifications |
| `common_node_exporter` | Host metrics exporter (CPU, RAM, Disk, Network) |
| `common_mysqld_exporter` | MariaDB metrics exporter |
| `common_fail2ban` | SSH + HTTP brute-force protection; writes to nftables banned sets |
| `common_msmtp` | SMTP relay for system notifications (rkhunter, cron, dnf-automatic) |
| `common_auditd` | Linux audit daemon with security-relevant rules |
| `common_rkhunter` | Rootkit detection with daily scan and email alerts |
| `common_dnf_automatic` | Automatic security-only updates |
| `next_packages` | Host packages for Nextcloud scenario |
| `next_mariadb` | Host MariaDB setup and Nextcloud database |
| `next_redis` | Host Redis for Nextcloud object cache and session storage |
| `next_selinux` | SELinux contexts for Nextcloud HostPath volumes |
| `next_k3s_deploy` | Nextcloud + Collabora Kubernetes manifests |
| `next_config` | Post-install Nextcloud occ configuration |
| `nextcloud_verify` | Post-deployment smoke tests for Nextcloud (31 checks) |
| `blog_packages` | Host packages for WordPress scenario |
| `blog_selinux` | SELinux contexts for WordPress HostPath volumes |
| `blog_k3s_deploy` | WordPress + MariaDB + Redis Kubernetes manifests |
| `blog_wordpress` | WordPress install, MU-plugin, plugins, Redis cache enable via WP-CLI |
| `blog_verify` | Post-deployment smoke tests for WordPress (26 checks) |

---

## Updating Component Versions

All pinned versions live in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml).
The `common_version_check` role compares them against latest releases at every playbook run.

```yaml
# Helm charts
ingress_nginx_chart_version: "2.5.1"
cert_manager_chart_version:  "1.20.2"

# Container images
blog_image_wordpress: "wordpress:7.0-php8.3-fpm"
blog_image_mariadb:   "mariadb:10.11"
blog_image_redis:     "redis:7-alpine"
blog_image_nginx:     "nginx:1.30-alpine"
```

To update: change the version tag in `all.yml` and re-run the playbook.
K3s and Helm are installed at latest by default (no pinned version).

---

## Documentation

Detailed operations guides are available in the `docs/` directory in three languages:

| Document | WordPress | Nextcloud |
|---|---|---|
| **Deutsch** | [wordpress-betrieb.html](docs/wordpress-betrieb.html) | [nextcloud-betrieb.html](docs/nextcloud-betrieb.html) |
| **English** | [wordpress-operations.html](docs/wordpress-operations.html) | [nextcloud-operations.html](docs/nextcloud-operations.html) |
| **Français** | [wordpress-exploitation.html](docs/wordpress-exploitation.html) | [nextcloud-exploitation.html](docs/nextcloud-exploitation.html) |

Each guide covers: architecture, configuration reference, playbook execution, performance optimisations, security layers, and troubleshooting.

---

## License

MIT License – see [LICENSE](LICENSE) for details.

You are free to use, modify and distribute this code. Please retain the copyright
notice and attribution to the original author.
