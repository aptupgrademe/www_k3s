# common_firewall

Deploys a hardened nftables firewall ruleset on AlmaLinux 9.

## What this role does

- Renders `/etc/sysconfig/nftables.conf` from the template `templates/fw.nft.j2`
- Enables and starts the `nftables` systemd service
- Uses `table inet` – a single ruleset covering both IPv4 and IPv6
- Default policy: **DROP** on INPUT, OUTPUT, and FORWARD
- Creates native nftables sets `banned4` (IPv4) and `banned6` (IPv6) with automatic timeout-based expiry; fail2ban writes banned IPs directly into these sets
- Drops malformed packets (XMAS, NULL), rate-limits RST floods, and rate-limits ICMP/ICMPv6

## Ports open by default

| Direction | Port / Protocol | Purpose |
|---|---|---|
| INPUT | 80, 443 TCP | HTTP/HTTPS (nginx-ingress) |
| INPUT | 10022 TCP | SSH (hardened port) |
| INPUT | from `k3s_pod_cidr` → 6443, 10250 TCP | Pods → K3s API server and kubelet (metrics-server) |
| OUTPUT | to `k3s_pod_cidr` new connections | Kubelet liveness/readiness probes (run in OUTPUT, not FORWARD) |
| INPUT | DHCPv4 (68←67), DHCPv6 (546←547) | Network configuration |
| INPUT/OUTPUT | established/related | Stateful connection tracking |
| INPUT | ICMPv4 (echo-request, time-exceeded, port-unreachable) | Rate-limited to 10/s |
| INPUT/OUTPUT | ICMPv6 (neighbour discovery, echo, etc.) | Required for IPv6 |

## K3s-specific exceptions (mandatory)

Without these three rules all pod controllers (cert-manager, coredns, metrics-server) crash:

1. **INPUT** `ip saddr {{ k3s_pod_cidr }} tcp dport { 6443, 10250 } accept`
   Pods need access to the K3s API server (port 6443, DNAT from ClusterIP 10.43.0.1:443)
   and to kubelet (port 10250, used by metrics-server).

2. **OUTPUT** `ip daddr {{ k3s_pod_cidr }} ct state new accept`
   Kubelet liveness and readiness probes originate from the host process and traverse
   the OUTPUT chain (not FORWARD). Without this rule probes fail and pods enter
   CrashLoopBackOff.

## Variables

| Variable | Example | Description |
|---|---|---|
| `k3s_pod_cidr` | `10.42.0.0/16` | K3s pod network (Flannel default) |
| `server_ipv4` | `1.2.3.4` | Public IPv4 address of the server |
| `server_ipv6` | `2a01::1` | Public IPv6 address (optional) |

## AlmaLinux 9 note

On AlmaLinux 9 the nftables configuration file is `/etc/sysconfig/nftables.conf`,
**not** `/etc/nftables.conf` (which is the path used on Debian/Ubuntu).
The systemd unit reads from `/etc/sysconfig/nftables.conf` via the
`/etc/nftables/` include mechanism. The role writes to the correct path.

## Interaction with K3s / iptables

K3s manages its own `KUBE-*` chains in the legacy iptables subsystem.
nftables and iptables are independent kernel subsystems on AlmaLinux 9 –
there are no lock conflicts or rule interference between them.
