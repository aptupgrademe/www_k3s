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
    │  HTTPS (443) / HTTP (80)
    ▼
┌─────────────────────────────────────────────┐
│  AlmaLinux 9 Host                           │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  K3s (single-node Kubernetes)       │    │
│  │                                     │    │
│  │  nginx-ingress (F5, hostNetwork)    │    │  ← TLS termination, rate limiting
│  │  cert-manager  (Let's Encrypt TLS)  │    │
│  │                                     │    │
│  │  Nextcloud pod  │  WordPress pod    │    │
│  │  Collabora pod  │  MariaDB pod      │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  Host services:                             │
│  MariaDB · Redis · Prometheus · Grafana     │  ← Nextcloud scenario only
│  Node Exporter · mysqld_exporter            │
│  Fail2Ban · nftables · auditd · rkhunter    │
└─────────────────────────────────────────────┘
```

---

## Features

### Application
- **Nextcloud 34** with PHP-FPM, nginx sidecar, Redis caching, MariaDB 10.11
- **Collabora CODE** (online office) with WOPI integration
- **WordPress 7.0** with PHP-FPM, nginx sidecar, MariaDB as K3s pod
- Automatic installation on first pod start via container env vars
- WordPress WP-Cron as Kubernetes CronJob

### Infrastructure
- **K3s** single-node Kubernetes (Flannel CNI)
- **F5 nginx-ingress** (nginx-stable Helm chart) with hostNetwork and DaemonSet
- **cert-manager** for automatic Let's Encrypt TLS certificates
- Mergeable Ingresses for ACME HTTP-01 challenge compatibility
- Kubernetes Secrets for all credentials (Ansible Vault encrypted locally)

### Security
- **nftables** hardened ruleset (`table inet`): default DROP, portscan detection, ICMP rate limiting — covers IPv4 and IPv6 in a single ruleset
- **Fail2Ban** writes banned IPs directly into nftables sets (`banned4`/`banned6`) with automatic timeout-based expiry
- **SELinux** enforcing with `container_file_t` contexts for HostPath volumes
- **auditd** with hardening rules (sudo, SSH, cron, kernel modules)
- **rkhunter** daily rootkit scan
- **dnf-automatic** for automatic security updates
- SSH hardened: non-default port, key-only authentication

### Monitoring
- **Prometheus** scraping Node Exporter, mysqld_exporter, php-fpm_exporter
- **Grafana** with three pre-imported dashboards:
  - Node Exporter Full (ID 1860) – CPU, RAM, Disk, Network
  - MySQL Overview (ID 7362) – MariaDB queries, InnoDB, slow queries
  - PHP-FPM (ID 4912) – FPM processes, request queue, slow requests
- MariaDB slow query log (threshold: 1 second)
- PHP-FPM slow log (threshold: 5 seconds)
- Grafana accessible at `https://<hostname>/grafana/`

### Backup & Restore
- `scripts/nextcloud-backup.sh <env>` – Nextcloud backup (Maintenance mode, mysqldump, rsync)
- `scripts/nextcloud-restore.sh <env>` – Full restore in 8 steps
- `scripts/wordpress-backup.sh` – WordPress backup via kubectl exec
- `scripts/wordpress-restore.sh` – Full restore including MariaDB reinitialisation

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
# Create host directory
mkdir -p inventory/host_vars/myserver

# Copy and fill in non-secret variables
cp inventory/host_vars/test/vars.yml inventory/host_vars/myserver/vars.yml
# Edit: server_ipv4, nextcloud_hostname, collabora_hostname, mail_*, ...

# Copy and fill in credentials
cp inventory/host_vars/test/vault.yml.example inventory/host_vars/myserver/vault.yml
# Edit: all changeme values with real passwords

# Encrypt the vault file (recommended)
ansible-vault encrypt inventory/host_vars/myserver/vault.yml
```

### 3. Deploy

```bash
# Nextcloud + Collabora
ansible-playbook nextcloud-k3s.yml --limit myserver --ask-vault-pass

# WordPress blog
ansible-playbook blog.yml --limit myserver --ask-vault-pass
```

After the first run, reboot the server to activate the firewall rules. Then update
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
│   ├── hosts.yml              # Server inventory
│   ├── group_vars/all.yml     # Shared variables (image versions, CIDRs)
│   └── host_vars/<host>/
│       ├── vars.yml           # Host-specific config (IPs, hostnames, SMTP)
│       ├── vault.yml          # Secrets – gitignored, never committed!
│       └── vault.yml.example  # Template with placeholder values
│
├── roles/
│   ├── common_*/              # Shared roles (K3s, SSH, Firewall, Monitoring)
│   ├── next_*/                # Nextcloud-specific roles
│   └── blog_*/                # WordPress-specific roles
│
├── scripts/
│   ├── nextcloud-backup.sh    # Backup: nextcloud-backup.sh <env>
│   ├── nextcloud-restore.sh   # Restore: nextcloud-restore.sh <env>
│   ├── wordpress-backup.sh    # WordPress backup
│   └── wordpress-restore.sh   # WordPress restore
│
└── docs/
    ├── nextcloud-betrieb.html     # Operations guide (German)
    ├── nextcloud-operations.html  # Operations guide (English)
    ├── wordpress-betrieb.html     # Operations guide (German)
    └── wordpress-operations.html  # Operations guide (English)
```

---

## Secrets Management

Credentials are **never committed** to this repository. The `.gitignore` excludes
all `vault.yml` files. Only `vault.yml.example` templates with placeholder values
are tracked.

```bash
# Workflow for secrets:
cp inventory/host_vars/<host>/vault.yml.example \
   inventory/host_vars/<host>/vault.yml
# Fill in real values, then optionally encrypt:
ansible-vault encrypt inventory/host_vars/<host>/vault.yml
```

Keep your `vault.yml` files in a **separate private repository** or encrypted backup.
Store the vault password in a password manager.

---

## Roles Overview

| Role | Purpose |
|---|---|
| `common_k3s` | K3s installation, Helm, cert-manager, F5 nginx-ingress |
| `common_firewall` | nftables hardening (table inet, banned4/banned6 sets) |
| `common_ssh` | SSH hardening (port, key-only) |
| `common_prometheus` | Prometheus metrics collector |
| `common_grafana` | Grafana with pre-imported dashboards |
| `common_node_exporter` | Host metrics exporter |
| `common_mysqld_exporter` | MariaDB metrics exporter (host service) |
| `common_fail2ban` | SSH brute-force protection |
| `common_msmtp` | SMTP relay for system notifications |
| `common_auditd` | Linux audit daemon |
| `common_rkhunter` | Rootkit detection |
| `common_dnf_automatic` | Automatic security updates |
| `next_packages` | Host packages for Nextcloud scenario |
| `next_mariadb` | Host MariaDB setup for Nextcloud |
| `next_redis` | Host Redis setup for Nextcloud |
| `next_selinux` | SELinux contexts for Nextcloud HostPath volumes |
| `next_k3s_deploy` | Nextcloud + Collabora Kubernetes manifests |
| `next_config` | Post-install Nextcloud occ configuration |
| `blog_packages` | Host packages for WordPress scenario |
| `blog_selinux` | SELinux contexts for WordPress HostPath volumes |
| `blog_k3s_deploy` | WordPress + MariaDB Kubernetes manifests |
| `blog_wordpress` | WordPress install and plugin setup via WP-CLI |

---

## License

MIT License – see [LICENSE](LICENSE) for details.

You are free to use, modify and distribute this code. Please retain the copyright
notice and attribution to the original author.
