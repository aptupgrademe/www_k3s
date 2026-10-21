# CLAUDE.md – working notes for AI assistants (and humans) in this repo

This file is read at the start of every Claude Code session. It holds **how we
work here and why things are the way they are**, so that the same lessons do
not have to be learned twice. It is public: no hostnames, addresses, provider
names, personal data or secrets – those stay in the gitignored inventory and
`docs/intern/`.

The long explanations live where the setting lives: in the comments of the
roles (look for "found 2026-…"), in `docs/` (operations guides in DE/EN/FR)
and in the README. This file only points the way and lists the traps.

## Layout

- Playbooks: `blog.yml` (WordPress host), `nextcloud-k3s.yml` (Nextcloud
  hosts), `blog-update.yml`, `nextcloud-update.yml` (updates, one host at a time).
- Roles: `common_*` (both stacks), `blog_*`, `next_*`. Shared roles decide by
  the play variable `stack` (`wordpress` / `nextcloud`), not by group names.
- Variables: `inventory/group_vars/all/main.yml`, pinned versions in
  `inventory/group_vars/all/versions.yml`. Real `host_vars` are gitignored;
  `*.example` files show the structure.
- Backup scripts: `scripts/nextcloud-backup/`, `scripts/wordpress-backup/`
  (live copies run on the backup machines; keep both in sync).

## How we work

- **Every change must work for both stacks** (blog and Nextcloud) – check and
  say so explicitly.
- **Lint the whole repo** before committing: `ansible-lint` (the CI runs it on
  everything, not per role). Pre-commit runs gitleaks, yamllint, ansible-lint.
- **Check mode first** (`--check --diff`), then the real run, **one host at a
  time** and with `-l <host>` (parallel runs on one host collided on the rpm
  lock). Afterwards a drift check (`scripts/check-drift.sh` or the same tags in
  `--check`) must show `changed=0`.
- **After any `--tags` run, also run `--tags common_rkhunter,common_aide_refresh`**,
  otherwise AIDE and rkhunter mail about the changed files at night.
- **Secret check before every commit and push**: read the full diff, grep for
  passwords/keys/IPs. Never print vault contents; mask passwords in command
  output (`MYSQL_PWD`, `REDISCLI_AUTH`, `sed` the `password`/`secret` lines).
- **No push without an explicit OK** from the repository owner.
- **Fix stale comments and docs immediately** when found; docs exist in three
  languages (`docs/*-operations|-betrieb|-exploitation.html`).
- **Delete only what is certainly dead** – data of disabled apps stays; back up
  first, count live rows.

## Traps we already fell into (and the rule that came out of it)

### SELinux
- **NoNewPrivileges blocks domain transitions.** Under NNP the policy only
  allows a transition into a domain that grants `nnp_transition`. MariaDB
  started via `/bin/sh` stayed in `initrc_t` for five weeks while everything
  said "enforcing" (fix: exec `mariadbd` directly). Redis needed the local module
  `homelab_redis_nnp` (`init_nnp_daemon_domain`). Many sandbox options
  (`SystemCallFilter`, `MemoryDenyWriteExecute`, `RestrictNamespaces`, …)
  **imply** NNP – leaving `NoNewPrivileges` out does not help.
- **After every unit/sandbox change: `ps -eZ | grep <daemon>`**, not only
  `systemctl status`. A daemon can be "active (running)" in the wrong domain.
- **K3s only confines pods with `selinux: true` and `k3s-selinux`**, and the
  binary must be relabelled (`restorecon`) after every download.
- **Files Ansible creates inherit the parent directory's type** (e.g. unit
  drop-in directories get `systemd_unit_file_t` instead of `mysqld_unit_file_t`)
  – `restorecon` after creating them.
- **Own domains (`homelab_*`) go through a permissive learning phase first.**
  Export the AVCs, review them, write the rules by hand with refpolicy macros.
  Never apply `audit2allow -M` blindly. Restart the service once in permissive
  mode to catch start-only accesses (bind, config reads) – `audit.log` rotates
  fast while a permissive domain floods it.
- `.fc` paths must use `/var/run/…`, not `/run/…` (`file_contexts.subs_dist`).

### systemd and SSH
- **SSH sessions are sandboxed** (no writes to kernel tunables, no namespaces):
  `sysctl -w`, `nsenter`, `tcpdump` fail there. Use
  `systemd-run --wait --pipe --collect …`.
- **`/tmp` is on disk and `noexec`** on the hosts; it is not emptied by a
  reboot. Clean up downloads/extractions yourself; run scripts from stdin.
- **`PrivateTmp=yes` and `TemporaryFileSystem=/tmp` must not be combined** –
  the private disk directory wins and the tmpfs is silently ignored.

### nftables and fail2ban
- **Replace only our own table** (`table inet filter` / `delete table inet
  filter` / rebuild, one transaction). `flush ruleset` also deletes K3s's tables
  (kube-proxy, flannel, network policies) and breaks pod → service traffic for
  30–90 s.
- **A reload empties our sets** – the handler restarts fail2ban, which re-applies
  its active bans.
- **One set pair per fail2ban jail** (`fail2ban_nft_jails`). With one shared set,
  the unban of a short jail removed addresses that a longer jail still banned.
  Monit's `f2b_sets` check compares fail2ban with the sets.
- **NodePorts are reachable on every local address**; the drop chain runs at
  priority −150 (after conntrack) and drops only `ct state new` – at `raw`
  priority it also dropped replies to outgoing pod connections.
- **Pod network namespaces copy the host's `all`/`default` sysctls** (e.g.
  `log_martians`) – set per interface where only the host is meant.
- MLD packets sit behind a hop-by-hop header, so `nexthdr ipv6-icmp` never
  matches them.

### Kubernetes / K3s
- **`subPath` mounts never update in a running pod.** The pod template carries a
  checksum annotation over every mounted ConfigMap **and Secret**; otherwise a
  changed config or rotated password only arrives at the next accidental restart.
- **NetworkPolicies are enforced by K3s's own controller** (kube-router). Calico
  never matched a pod here (Flannel creates `veth*`, Felix only handles `cali*`).
- In PromQL, `sum` over a container name adds old and new pods during a rollout
  – aggregate `by (pod)`.

### Nextcloud
- **OPcache runs with `validate_timestamps=0`** – after `occ upgrade` or
  `occ app:update` the pod must be restarted, or old bytecode keeps running.
- Config files load as `config.php`, then `*.config.php` alphabetically (later
  wins). notify_push reads only `config.php`.
- **Previews are tracked in the database** (`oc_previews`) since NC 32 – remove
  them with `occ preview:cleanup`, never with `rm`.
- The preview JPEG quality is an app config value (`preview jpeg_quality`),
  not a `config.php` key.

### WordPress
- **wp-cli only as `www-data`** – `--allow-root` once left root-owned cache files.
- **Write `post_content` only through WordPress functions** (`wp_slash`) – a
  direct update stripped backslashes from code examples.
- Read the live post and its `post_modified` before changing it; never overwrite
  edits made in the meantime. DB dump first.
- Some posts store `\r\n` line endings (the older English originals) – a
  string replacement written with `\n` silently matches nothing; check both.
- `wp_insert_post()` from `wp eval`/`eval-file` has no current user: pass
  `post_author` (20 posts/pages had author 0 – empty byline link to `/author/`,
  404, no author in the schema). Link posts by permalink, not `?p=ID`.
- Set the featured image **before** publishing (Yoast builds its og:image then).
- `wp cache flush` empties the object cache only; the page cache needs
  `wp_cache_clear_cache()`.
- CompressX creates its WebP/AVIF companions automatically only with
  `compressx_auto_optimize` on (set by `blog_wordpress`).

### Monitoring and alerts
- **Grafana alert rules need `condition`**; with `execErrState: OK` a broken rule
  looks green forever. Check the rule state, not the absence of mail.
- Monit watches the services Prometheus/Grafana cannot alert about themselves
  (if Prometheus stops, every rule stays quietly green).

### CI
- **No apostrophe in a comment inside a `shell:` block** – ansible-lint fails
  with `parser-error: failed at splitting arguments` (unbalanced quote).
- A Lint failure after ~30 s is usually `ansible-galaxy` (cache/download), not
  the code – re-run before changing anything.
