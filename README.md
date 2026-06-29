# Homelab Ansible – Nextcloud, WordPress & NAS

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Ansible](https://img.shields.io/badge/Ansible-2.15+-red.svg)](https://www.ansible.com/)
[![K3s](https://img.shields.io/badge/K3s-latest-blue.svg)](https://k3s.io/)
[![AlmaLinux](https://img.shields.io/badge/AlmaLinux-9-green.svg)](https://almalinux.org/)
[![Debian](https://img.shields.io/badge/Debian-13-A81D33.svg)](https://debian.org/)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-34-0082C9.svg)](https://nextcloud.com/)
[![WordPress](https://img.shields.io/badge/WordPress-7.0-21759B.svg)](https://wordpress.org/)

Ansible playbooks to deploy and manage a fully automated homelab – both
**internet-facing servers** (K3s on AlmaLinux 9) and **local network machines**
(Debian 13, e.g. a NAS).

The goal is to be able to rebuild any machine from scratch using a single
`ansible-playbook` command.

Three independent deployment scenarios:

| Scenario | Playbook | Target | What gets deployed |
|---|---|---|---|
| **Nextcloud** | `nextcloud-k3s.yml` | Internet VPS (AlmaLinux 9) | Nextcloud + Collabora CODE (online office) on K3s |
| **WordPress** | `blog.yml` | Internet VPS (AlmaLinux 9) | WordPress blog on K3s |
| **NAS** | `nas.yml` | Local LAN (Debian 13) | OpenZFS RAIDZ1, Samba, Jenkins, Pi-hole, GitLab CE |

The internet scenarios share a common infrastructure layer (K3s, nginx-ingress,
cert-manager, Prometheus, Grafana, Fail2Ban, nftables hardening).
The NAS scenario uses a Debian-specific stack without internet-facing services.

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

### Local NAS (hp1 · Debian 13 · 192.168.10.50)

```
Local Network (192.168.10.x)
    │  SMB (445) · HTTP (8000/4443 Pi-hole) · HTTP (80 GitLab)
    ▼
┌─────────────────────────────────────────────────────────────┐
│  HP MicroServer Gen10 Plus V2 / hp1 · Xeon E-2314 · 31 GB   │
│                                                             │
│  sdb  465 GB SSD  → Debian 13 OS                           │
│  sda │                                                      │
│  sdc ├─ ZFS RAIDZ1 "data" (3×1.8 TB, zstd) → /raid5       │
│  sdd │    ├── data/shared   (Samba share)                   │
│       │    └── data/angelika (Samba share)                  │
│  sde  1.8 TB HDD  → /mnt/usb (external backup)             │
│                                                             │
│  Services:                                                  │
│  smbd/nmbd    → Samba file sharing (SMB3)                   │
│  jenkins      → Backup jobs (Nextcloud CVJM, Sofie) :8090  │
│  pihole-FTL   → DNS ad-blocker :8000/:4443                  │
│  gitlab-ce    → Local Git server :80                        │
│  smartd       → SMART disk health monitoring                │
│  zed           → ZFS event daemon (email on disk error)     │
│  unattended-upgrades → automatic security updates           │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

### Internet Scenarios (Nextcloud & WordPress)

- **Nextcloud 34** with PHP-FPM, nginx sidecar, Redis (host service) and MariaDB 10.11
- **Collabora CODE** (online office) with WOPI integration
- **WordPress 7.0** with PHP-FPM, nginx sidecar, MariaDB pod and **Redis Object Cache** pod
- Automatic installation on first pod start via container env vars and WP-CLI
- WordPress WP-Cron as Kubernetes CronJob (no HTTP trigger)
- **Pre-flight version check** (`common_version_check`) shows installed vs. latest versions
- **Ansible pipelining**, fact caching (1 h), SSH ControlPersist 600 s

### NAS Scenario (hp1)

- **OpenZFS RAIDZ1** on 3× WD Red SA500 SSDs (1.8 TB each, zstd compression, 1M recordsize)
- **Samba** (SMB3) with two shares; adding a share in `vars.yml` automatically creates the ZFS dataset
- **Jenkins** (port 8090) with two daily backup jobs (Nextcloud CVJM + Sofie via rsync)
- **Pi-hole v6** DNS ad-blocker (port 8000/4443, upstream 8.8.8.8/8.8.4.4)
- **GitLab CE 19.1** local Git server (port 80, prometheus disabled)
- **HPE AMSD** (Agentless Management Service) – required for **automatic fan speed control** on the HP MicroServer Gen10 Plus V2; without it the server runs at maximum fan speed
- **SSH key restore** – raphael's backup SSH keys restored from vault to `/home/raphael/.ssh/`
- **SMART monitoring** – daily/weekly self-tests on all 5 drives with email alerts
- **ZED** – ZFS Event Daemon emails on pool degradation; monthly scrub cron
- **unattended-upgrades** – Debian security updates (equivalent of dnf-automatic)
- **autotrim** – automatic TRIM for SSD health

### Performance (both)

| Feature | Where | Effect |
|---|---|---|
| **HTTP/2** | nginx-ingress | Multiplexing, HPACK header compression |
| **Brotli compression** | nginx-ingress | 15–25% smaller responses vs. gzip |
| **OCSP Stapling** | nginx-ingress | Saves one CA round-trip per TLS handshake |
| **ZFS zstd** | NAS | ~30–50% space saving on documents/backups |
| **ZFS autotrim** | NAS | SSD health maintenance |
| **Redis Object Cache** | WordPress pod | DB queries replaced by Redis lookups |
| **PHP OPcache** | PHP-FPM | Bytecode cached in memory |
| **/tmp on RAM (tmpfs)** | WordPress / Nextcloud FPM | 64 Mi emptyDir – PHP temp files bypass disk |
| **TCP BBR** | Host kernel | Better throughput on congested links |
| **THP madvise** | Host kernel | Prevents latency spikes in ZFS, MariaDB, Redis |
| `tcp_max_syn_backlog=4096` | Host kernel | Avoids SYN drops under burst traffic |

### Security

#### Firewall – nftables (internet servers)

- `table inet` ruleset covering IPv4 and IPv6 in one ruleset
- Default **DROP policy** on INPUT and FORWARD
- Whitelist-only: SSH (port 10022), HTTP (80), HTTPS (443), ICMP rate-limited
- `banned4` / `banned6` nftables sets with native timeout

#### Intrusion Detection – Fail2Ban (internet servers)

| Jail | Trigger | Ban |
|---|---|---|
| `sshd` | Failed SSH login (3× / 10 min) | 1 h |
| `nginx-k3s-wp-login` | POST `/wp-login.php` (10× / 10 min) | 1 h |
| `nginx-k3s-scanner` | 403/404 storm (20× / 60 s) | 1 h |
| `nginx-k3s-bad-paths` | Known-malicious paths | 24 h |
| `recidive` | Banned 3× in one day | **30 days** |

#### TLS / HTTPS

| Setting | Value |
|---|---|
| Protocols | TLS 1.2 + 1.3 only |
| OCSP Stapling | on (resolver 1.1.1.1/8.8.8.8) |
| `ssl_session_tickets` | off (Perfect Forward Secrecy) |
| HSTS | `max-age=31536000; includeSubDomains; preload` |

#### System Hardening (all machines)

- **SELinux enforcing** (AlmaLinux) / **SSH key-only** (Debian NAS)
- **auditd** with security-relevant rules
- **rkhunter** daily scan with email alerts (AlmaLinux) / **SMART** (NAS)
- **dnf-automatic** (AlmaLinux) / **unattended-upgrades** (Debian) for auto security updates
- **systemd hardening** drop-ins for sshd, node_exporter, prometheus

---

## Requirements

### Control node (your machine)
- Ansible 2.15+
- Python 3.8+
- `community.general` and `ansible.posix` collections

### Internet servers (AlmaLinux 9)
- Fresh AlmaLinux 9 install
- Min. 4 GB RAM (8 GB recommended with Collabora)
- Public IPv4 with DNS A-records
- SSH root access on port 22 (switches to 10022 after first run)

### NAS – hp1 (Debian 13, local LAN)
- Fresh Debian 13 (Trixie) install on sdb (465 GB SSD)
- 3× data SSDs free of partitions (sda, sdc, sdd) for ZFS
- Reachable on 192.168.10.50 from the Ansible control node
- SSH key deployed: `ssh-copy-id raphael@192.168.10.50`

---

## Quick Start

### Internet servers

```bash
git clone https://github.com/aptupgrademe/www_k3s.git
cd www_k3s

# Set up inventory
cp inventory/host_vars/test/vars.yml inventory/host_vars/myserver/vars.yml
cp inventory/host_vars/test/vault.yml.example inventory/host_vars/myserver/vault.yml
# Fill in passwords, then encrypt:
ansible-vault encrypt inventory/host_vars/myserver/vault.yml

# Deploy Nextcloud
ansible-playbook nextcloud-k3s.yml --limit myserver --ask-vault-pass

# Deploy WordPress
ansible-playbook blog.yml --limit myserver --ask-vault-pass
```

### NAS (hp1)

```bash
# Set up host vars
cp inventory/host_vars/hp1/vars.yml.example inventory/host_vars/hp1/vars.yml
cp inventory/host_vars/hp1/vault.yml.example inventory/host_vars/hp1/vault.yml
# Fill in passwords + paste SSH private keys, then encrypt:
ansible-vault encrypt inventory/host_vars/hp1/vault.yml

# Deploy SSH key first
ssh-copy-id raphael@192.168.10.50

# Run NAS playbook
ansible-playbook nas.yml --ask-vault-pass
```

> **Note (NAS):** The playbook aborts if `/dev/md0` (Linux software RAID) still
> exists on the data SSDs. Back up all data from `/raid5` and dissolve the md array
> first. See migration notes in `nas.yml`.

---

## Project Structure

```
www_k3s/
├── nextcloud-k3s.yml          # Nextcloud + Collabora playbook (internet)
├── blog.yml                   # WordPress playbook (internet)
├── nas.yml                    # NAS playbook (local LAN – hp1)
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
│   ├── common_*/              # Shared roles (K3s, SSH, Firewall, Monitoring, …)
│   ├── next_*/                # Nextcloud-specific roles
│   ├── blog_*/                # WordPress-specific roles
│   └── nas_*/                 # NAS-specific roles (ZFS, Samba, Jenkins, Pi-hole, GitLab)
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
    ├── nextcloud-exploitation.html  # Nextcloud – Guide d'exploitation (FR)
    ├── nas-betrieb.html             # NAS hp1 – Betriebsdokumentation (DE)
    ├── nas-operations.html          # NAS hp1 – Operations guide (EN)
    ├── nas-exploitation.html        # NAS hp1 – Guide d'exploitation (FR)
    └── cvjm-nextcloud-audit.md      # Audit report: nextcloud.cvjm-gn.de
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
# Fill in real values (including SSH private keys for NAS), then encrypt:
ansible-vault encrypt inventory/host_vars/<host>/vault.yml
```

---

## Roles Overview

### Common (internet + NAS)

| Role | Purpose |
|---|---|
| `common_sysctl` | Kernel tuning: TCP BBR, backlog=4096, THP madvise |
| `common_msmtp` | SMTP relay for system notifications (cross-distro: dnf + apt) |
| `common_apt_automatic` | Automatic security updates on Debian (unattended-upgrades) |
| `common_dnf_automatic` | Automatic security updates on AlmaLinux |
| `common_logrotate` | Log rotation for Grafana, fail2ban, rkhunter |

### Internet servers (AlmaLinux 9 + K3s)

| Role | Purpose |
|---|---|
| `common_version_check` | Pre-flight: K3s, Helm, chart and image versions vs. latest |
| `common_k3s` | K3s, Helm, cert-manager, F5 nginx-ingress (HTTP/2, Brotli, OCSP) |
| `common_firewall` | nftables (table inet, banned4/banned6 sets, K3s exceptions) |
| `common_ssh` | SSH hardening (port 10022, key-only, PermitRootLogin without-password) |
| `common_prometheus` | Prometheus metrics collector |
| `common_grafana` | Grafana dashboards + alert rules |
| `common_node_exporter` | Host metrics exporter |
| `common_mysqld_exporter` | MariaDB metrics exporter |
| `common_fail2ban` | Brute-force protection; writes to nftables banned sets |
| `common_auditd` | Linux audit daemon |
| `common_rkhunter` | Rootkit detection with daily scan |
| `next_*` | Nextcloud + Collabora roles |
| `blog_*` | WordPress + Redis Object Cache roles |

### NAS (Debian 13 · hp1)

| Role | Purpose |
|---|---|
| `nas_packages` | OpenZFS, Samba, Jenkins, Java 21, utilities (tmux, rsync, rdiff-backup); **HPE AMSD** first |
| `nas_system` | Hostname, timezone (Europe/Berlin), locale, SSH keys restore, sde mount |
| `nas_zfs` | RAIDZ1 pool "data" on sda/sdc/sdd; datasets from `nas_samba_shares` (zstd, 1M recordsize) |
| `nas_zed` | ZFS Event Daemon: email on pool error; monthly scrub cron |
| `nas_smart` | smartd: daily short tests, weekly long tests, temperature alerts |
| `nas_samba` | smb.conf; shares auto-created from `nas_samba_shares` (single source of truth) |
| `nas_jenkins` | Jenkins port 8090; jobs Backup-CVJM + Backup-Sofie |
| `nas_pihole` | Pi-hole v6 (port 8000/4443, DNS 8.8.8.8/8.8.4.4, interface eno1) |
| `nas_gitlab` | GitLab CE 19.1 (http://192.168.10.50, prometheus disabled, homelab tuning) |

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
nextcloud_image_fpm:  "nextcloud:34-fpm"

# NAS: pin GitLab version in host_vars/hp1/vars.yml
nas_gitlab_version: "19.1.1-ce.0"
```

---

## Documentation

### Internet servers

| Document | WordPress | Nextcloud |
|---|---|---|
| **Deutsch** | [wordpress-betrieb.html](docs/wordpress-betrieb.html) | [nextcloud-betrieb.html](docs/nextcloud-betrieb.html) |
| **English** | [wordpress-operations.html](docs/wordpress-operations.html) | [nextcloud-operations.html](docs/nextcloud-operations.html) |
| **Français** | [wordpress-exploitation.html](docs/wordpress-exploitation.html) | [nextcloud-exploitation.html](docs/nextcloud-exploitation.html) |

### NAS hp1 (Debian 13 · OpenZFS · 192.168.10.50)

| Sprache | Dokument |
|---|---|
| **Deutsch** | [nas-betrieb.html](docs/nas-betrieb.html) |
| **English** | [nas-operations.html](docs/nas-operations.html) |
| **Français** | [nas-exploitation.html](docs/nas-exploitation.html) |

Each guide covers: architecture, hardware, configuration, playbook execution,
ZFS management, Samba, Jenkins, Pi-hole, GitLab, performance and troubleshooting.

---

## License

MIT License – see [LICENSE](LICENSE) for details.

You are free to use, modify and distribute this code. Please retain the copyright
notice and attribution to the original author.
