# WordPress backup (pull, rsync + rdiff-backup)

Runs on the same **backup machine** as the Nextcloud backup (not on the blog
host). It pulls the blog over SSH as root and needs no password: the database
dump runs inside the MariaDB pod via `kubectl exec` and reads the root password
from the secret file mounted there.

```
/data/backup/wordpress/            scripts (a copy of this folder) + logs/
/data/backup/wordpress-data/<name>/
    db/     wordpress_<date>_<time>.sql.gz   (last 14, verified before kept)
    www/    blog_k3s_www_dir (/srv/wordpress-www): core, wp-content, wp-config.php
    last-success
/data/backup/wordpress-rdiff/      rdiff-backup history of wordpress-data (30 days)
```

All of it is created with `umask 077`: `wp-config.php` and the dumps hold
credentials and every user's password hash.

| File | Tracked | Purpose |
|---|---|---|
| `wp_backup_lib.sh` | yes | Backup logic: wait for SSH, rsync, dump + verify, rsync delta, stamp |
| `wp_rdiff.sh` | yes | Versions the instances in `INSTANCES`; waits for running backups |
| `example_backup.sh.example` | yes | Template for one instance |
| `<name>_backup.sh` | **no** (gitignored) | Filled-in copy with the real hostname |

Same three steps as the Nextcloud backup, without maintenance mode: rsync,
`mariadb-dump --single-transaction` (written to `.part`, kept only after
`gzip -t` and the "Dump completed" marker), then a short second rsync.

This is the off-host copy. The nightly `wordpress-autoupdate` CronJob also
writes a DB dump before updating, but to `/srv/wordpress-update-backups/` on the
blog host itself, so it doesn't protect against losing the server.

## Setup

```bash
mkdir -p /data/backup/wordpress && cp -a scripts/wordpress-backup/. /data/backup/wordpress/
cd /data/backup/wordpress && cp example_backup.sh.example blog_backup.sh   # fill in, chmod 750
crontab -e
  @reboot     sleep 300; /data/backup/wordpress/blog_backup.sh
  45 12 * * * /data/backup/wordpress/blog_backup.sh
  @reboot     sleep 1500; /data/backup/wordpress/wp_rdiff.sh
  30 13 * * * /data/backup/wordpress/wp_rdiff.sh
```

After every success the blog host gets `/var/lib/wordpress-backup/last-success`.
Monit (`common_monit`, check `wp_backup`) alerts when it is older than
`monit_backup_max_days` (3).


### Split setup: pull host and versioning host

The pull and the versioning can live on different machines, e.g. an always-on NAS that pulls
nightly into its own storage, and a backup PC that only versions what the NAS has:

```sh
# on the NAS (as root), per instance script before sourcing the library:
DATA_ROOT=/storage                    # -> /storage/<name>/{db,www}
LOGDIR=/var/log/backup/wordpress
SSH_KEY=/root/.ssh/id_rsa

# on the backup PC: rdiff-backup over SSH (same rdiff-backup version on both sides)
30 13 * * * SRC=root@nas::/storage /data/backup/wordpress/wp_rdiff.sh
```

With a remote `SRC`, `wp_rdiff.sh` first waits on the NAS for a running backup of each instance
and refuses to run if an instance has no `last-success` or an empty `www/` (versioning an empty
source would record everything as deleted).

## Restore

```bash
B=/data/backup/wordpress-data/blog      # or an older state:
# rdiff-backup --api-version 201 restore --at 3D /data/backup/wordpress-rdiff/blog /tmp/blog-3d && B=/tmp/blog-3d
H=root@<blog-host>; SSH="ssh -p 10022"

# 1. Files back into the hostPath (owner www-data = 33)
rsync -rlptD --delete -e "$SSH" "$B/www/" "$H:/srv/wordpress-www/"
$SSH $H 'chown -R 33:33 /srv/wordpress-www'

# 2. Database
zcat "$(ls -1t $B/db/wordpress_*.sql.gz | head -1)" | $SSH $H \
  "k3s kubectl -n wordpress exec -i deploy/mariadb -c mariadb -- sh -c 'MYSQL_PWD=\"\$(cat /etc/secrets/db-root-password)\" mariadb -u root \"\$MARIADB_DATABASE\"'"

# 3. Restart the pod and flush caches
$SSH $H 'k3s kubectl -n wordpress rollout restart deploy/wordpress'
```
