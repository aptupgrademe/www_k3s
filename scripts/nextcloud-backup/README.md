# Nextcloud backup (pull, rsync + rdiff-backup)

Runs on a **backup machine** (not on the Nextcloud host). It pulls each
instance over SSH as root and needs no password: the DB dump uses
`/root/.my.cnf` on the instance.

```
/data/backup/nextcloud/            scripts (a copy of this folder) + logs/
/data/backup/nextcloud-data/<name>/
    db/     <db>_<date>_<time>.sql.gz   (last 14, verified before kept)
    www/    code + config/config.php     (K3s: /srv/nextcloud-www)
    data/   data directory incl. previews
    last-success
/data/backup/nextcloud-rdiff/      rdiff-backup history of nextcloud-data (30 days)
```

| File | Tracked | Purpose |
|---|---|---|
| `nc_backup_lib.sh` | yes | Backup logic: wait for SSH, rsync, dump + verify, rsync delta, stamp |
| `nc_rdiff.sh` | yes | Versions the instances in `INSTANCES`; waits for running backups |
| `example_backup.sh.example` | yes | Template for one instance |
| `<name>_backup.sh` | **no** (gitignored) | Filled-in copy with the real hostname |

**How a run works, without maintenance mode on purpose:** the backup runs when
the backup machine boots and daily, often during the day, and a maintenance mode
would lock users out. Instead:

1. **rsync www + data**: moves almost everything and may take long.
2. **DB dump** (`--single-transaction`): consistent on its own, locks nothing,
   written to `.part` and kept only after `gzip -t` plus the
   "Dump completed" marker check.
3. **rsync www + data again**: only what changed since step 1, which is short.

So the dump and the files end up only seconds to a few minutes apart. The log
reports the gap ("Abstand Dump-Start -> Dateien final"). Anything that changed
inside it is reconciled after a restore by `occ files:scan --all`, which
`scripts/nextcloud-restore.sh` runs. At worst, metadata created in those
minutes (e.g. a new share) is missing. File data is never broken.

## Setup

```bash
cp -a scripts/nextcloud-backup/. /data/backup/nextcloud/
cp example_backup.sh.example cvjm_backup.sh   # fill in, chmod 750
crontab -e
  @reboot     /data/backup/nextcloud/cvjm_backup.sh
  30 12 * * * /data/backup/nextcloud/cvjm_backup.sh
  @reboot     sleep 900; /data/backup/nextcloud/nc_rdiff.sh
  15 13 * * * /data/backup/nextcloud/nc_rdiff.sh
```

The backup machine's `~/.ssh/known_hosts` must already hold each instance's
host key, because the scripts use `BatchMode`. After every success the instance
gets `/var/lib/nextcloud-backup/last-success`. Monit (`common_monit`, check
`nc_backup`) alerts when it is older than `monit_backup_max_days` (3).

## Restore (K3s instance)

```bash
B=/data/backup/nextcloud-data/cvjm          # or an older state from rdiff:
# rdiff-backup --api-version 201 restore --at 3D /data/backup/nextcloud-rdiff/cvjm /tmp/cvjm-3d
ssh root@HOST 'k3s kubectl scale deploy/nextcloud -n nextcloud --replicas=0'
rsync -a --delete $B/www/  root@HOST:/srv/nextcloud-www/
rsync -a --delete $B/data/ root@HOST:/data/
ssh root@HOST 'chown -R 33:33 /srv/nextcloud-www /data'
zcat $B/db/<db>_<latest>.sql.gz | ssh root@HOST 'mysql <db>'
ssh root@HOST 'k3s kubectl scale deploy/nextcloud -n nextcloud --replicas=1'
# then, as www-data in the nextcloud-fpm container:
#   occ maintenance:data-fingerprint && occ files:scan --all
```

The backup copies are owned by the backup user (owners can't be kept without
root), hence the `chown` to www-data (33). On a native install use
`/var/www/html/nextcloud` for www and restart PHP-FPM instead of scaling.
