# Nextcloud migration runbook — bare metal to K3s

Findings from a full dress rehearsal: an existing native Nextcloud installation
was restored onto the K3s stack, walked through the major version path, and the
resulting database was analysed and cleaned. Everything below was measured on
that rehearsal server, not taken from documentation.

The numbers are from one instance (151 users, ~55k user files, 363 GB of data,
27 GB of appdata). Treat them as orders of magnitude, not promises.

---

## 1. The restored database keeps the old server's file index

This is the single most expensive artefact of the migration, and it is
invisible until you go looking for it.

Nextcloud records every file in `oc_filecache`, keyed by a numeric storage id,
and `oc_storages` maps that id to a path string such as
`local::/var/www/html/nextcloud/data/`. Restoring the old server's database
brings those rows along. The new instance then creates a *second* storage row
for its own data directory and starts indexing into that one — so the same
physical data ends up indexed two or three times under different path strings.

On the rehearsal instance:

| storage | rows | meaning |
|---|---|---|
| `local::/var/www/html/nextcloud/data/` | 553,715 | the old native server's path |
| `local::/data/` | 421,558 | an earlier container mapping |
| `local::/var/www/html/data/` | 2,995 | the current, live one |

**975,273 of 1,047,536 filecache rows — 93 % — belonged to superseded storages.**
`oc_filecache` alone was 765 MB of a 932 MB database.

Expect the same on the production cutover: the old server's data directory path
will differ from the new one, so the stale storage will reappear.

### How to find it

```sql
-- every storage, its row count, and whether anything still mounts it
SELECT s.numeric_id, s.id, COUNT(fc.fileid) AS rows,
       (SELECT COUNT(*) FROM oc_mounts m WHERE m.storage_id = s.numeric_id) AS mounts
FROM oc_storages s
LEFT JOIN oc_filecache fc ON fc.storage = s.numeric_id
WHERE s.id LIKE 'local::%'
GROUP BY s.numeric_id, s.id
ORDER BY rows DESC;
```

The live storage is the one holding the highest `fileid`, not the one with the
most rows:

```sql
SELECT s.id, MAX(fc.fileid), COUNT(*)
FROM oc_filecache fc JOIN oc_storages s ON s.numeric_id = fc.storage
WHERE s.id LIKE 'local::%' GROUP BY s.id;
```

---

## 2. `occ files:cleanup` does nothing on its own

The obvious command is a no-op here, and it is worth understanding why before
concluding the database is fine.

`files:cleanup` deletes filecache rows whose `storage` value has **no matching
row in `oc_storages`**. It does not check whether the storage's path exists on
disk. A stale storage still has its `oc_storages` row, so its million rows are
not orphans by that definition.

Measured on the rehearsal instance, before touching anything:

```
0 orphaned file cache entries deleted
0 orphaned file cache extended entries deleted
0 orphaned mount entries deleted
```

The row has to be deleted first; only then does `files:cleanup` see the
filecache rows as orphaned and remove them, along with any orphaned mounts.

---

## 3. Check what still depends on the stale storage — this bites

**Do not delete a storage row before running these three checks.** On the
rehearsal instance the old storage was not inert: two users had an active share
mounted from it.

```sql
-- (a) does anything mount it?
SELECT user_id, mount_point, mount_provider_class
FROM oc_mounts WHERE storage_id = <id>;

-- (b) do any shares originate from it?
SELECT s.id, s.share_type, s.uid_owner, s.share_with, fc.path
FROM oc_share s JOIN oc_filecache fc ON fc.fileid = s.file_source
WHERE fc.storage = <id>;

-- (c) THE IMPORTANT ONE: are there real user files, or only appdata?
SELECT SUBSTRING_INDEX(path, '/', 1) AS root, COUNT(*)
FROM oc_filecache WHERE storage = <id>
GROUP BY root ORDER BY COUNT(*) DESC;
SELECT COUNT(*) FROM oc_filecache WHERE storage = <id> AND path LIKE 'files/%';
```

Check (c) decides whether deletion is safe. On the rehearsal instance both stale
storages contained **only** `appdata_*` — previews, thumbnails and app caches,
all regenerable — and **zero** rows under `files/`. Every real user file lived
on a `home::<user>` storage, which the cleanup never touches.

The three shares found by check (b) pointed at `appdata_.../collectives/1`, from
the Collectives app, which is no longer installed — so they were already
non-functional and were removed with the storage. Had they pointed at real user
content, the correct move would have been to repoint them, not delete them.

---

## 4. Procedure that worked

Order matters. Timings are from the rehearsal instance.

```bash
# 0. A restorable copy first. Maintenance mode keeps the dump consistent.
occ maintenance:mode --on
mysqldump --single-transaction --quick --routines --events <db> | gzip -1 > dump.sql.gz
occ maintenance:mode --off
#    ~70 MB gzipped for a 932 MB database

# 1. Record control values you will verify against afterwards
SELECT COUNT(*) FROM oc_filecache WHERE path LIKE 'files/%';   -- user files
SELECT COUNT(*) FROM oc_share;                                  -- shares
SELECT COUNT(*) FROM oc_users;                                  -- users

# 2. Remove shares that originate from the stale storage, if check (b) found
#    any AND they are genuinely dead (app uninstalled, target gone)
DELETE s FROM oc_share s
  JOIN oc_filecache fc ON fc.fileid = s.file_source
  WHERE fc.storage = <id>;

# 3. Remove the storage row
DELETE FROM oc_storages WHERE numeric_id = <id>;

# 4. Now the cleanup finds the orphans
occ files:cleanup
#    553,715 rows in 57 s for the first storage; 421,558 in 22 s for the second

# 5. Reclaim the space (see section 5)
OPTIMIZE TABLE oc_filecache;
#    13 s

# 6. Deal with what is left physically on disk but no longer indexed.
#    Do NOT reach for files:scan-app-data first - see the section below.
rm -rf <datadir>/appdata_<instanceid>/preview   # regenerable cache, 26 GB here
occ files:scan-app-data                          # only if you need the rest indexed
```

Step 6 applies only to the *duplicate* case, where the stale storage indexed
files that still exist. A storage pointing at a path that no longer exists —
the old server's — needs nothing here: there is nothing on disk to reconcile.

### Verify afterwards

```bash
occ status                       # installed, no needsDbUpgrade
occ user:list | wc -l            # unchanged
curl -sk https://<host>/status.php
curl -sk -o /dev/null -w '%{http_code}' https://<host>/login
```

Plus the control values from step 1. On the rehearsal instance user files
stayed at exactly 55,488 through both cleanups.

---

## 5. Deleting rows makes the database *bigger* until you optimise

Counter-intuitive and worth planning for. InnoDB releases deleted pages inside
the tablespace but does not return them to the filesystem.

Measured:

| stage | database size |
|---|---|
| before | 932.1 MB |
| after deleting 553,715 rows | **993.0 MB** (166 MB "free" inside the file) |
| after `OPTIMIZE TABLE oc_filecache` | **533.8 MB** |

`oc_filecache` itself went 765.6 → 306.4 MB. The optimise took 13 seconds, but
it is a full table rebuild: it needs temporary disk space roughly the size of
the table, and it locks the table while it runs. Budget for both.

Final result across both cleanups: **932 MB → 393 MB, a 58 % reduction**, with
filecache rows going from 1,047,536 to 147,219.

### The rescan is the expensive part — and previews are a cache, not data

Step 6 of the procedure (`occ files:scan-app-data`) is where the rehearsal ran
into a wall, and the lesson matters more than the cleanup itself.

After removing the duplicate storage, 26 GB of preview files (104,017 of them,
spread over 480,847 directories) were left on disk with no index. Re-indexing
them took **23 minutes to cover roughly 13 %** before the process died; a full
run would have taken hours and would have put ~500,000 rows straight back into
the table that was just cleaned.

That is the wrong trade. **Previews are a regenerable cache.** The cheaper and
cleaner move is to delete the orphaned preview tree outright and let Nextcloud
rebuild previews on demand (or via the `previewgenerator` cron):

```bash
# only the preview subtree, never the whole appdata directory - avatars,
# theming, appstore and identityproof live there too and are NOT regenerable
rm -rf <datadir>/appdata_<instanceid>/preview
```

This reclaims the disk *and* keeps the database small, instead of trading one
for the other. Run `occ files:scan-app-data` only for the appdata subtrees you
actually need indexed.

A caveat on measuring the end state: the database keeps growing slowly
afterwards as previews are regenerated and re-indexed. 393 MB is the floor
right after the cleanup, not a steady state. The part that genuinely cannot come
back is the old server's storage plus the OnlyOffice debris — together roughly
830,000 of the original 1,047,536 rows.

---

## 6. Other things found in the same database

Smaller, but all of it survives a restore and none of it is obvious.

**Tables from apps that are no longer installed** — roughly 48 MB. The app
directories are gone and the apps appear in neither the enabled nor the
disabled list, but their tables, `oc_appconfig` rows and `oc_preferences` rows
remain:

| app | tables | size |
|---|---|---|
| maps | 2 | 33 MB |
| OnlyOffice (see below) | 7 | 10.1 MB |
| files_antivirus | 1 | 2.5 MB |
| spreed (Talk), polls, collectives, groupfolders, ojsxc | 40 | ~2.5 MB |

Plus 89 orphaned `oc_appconfig` and 358 `oc_preferences` rows. To find them,
list the tables and match their prefixes against the installed app directories —
but verify each candidate individually, because the mapping is not mechanical
(`oc_login_ips_aggregated` belongs to `suspicious_login`, which *is* installed).

### OnlyOffice is gone for good — Collabora is the office integration

Confirmed by the operator: this instance uses **Collabora only**
(`richdocuments` 11.1.1 plus the `collabora` pod). OnlyOffice will not come
back, so every trace of it can be removed without the usual "might be needed
later" hesitation:

```sql
-- 7 tables, ~10.1 MB
DROP TABLE IF EXISTS oc_documentserver_changes, oc_documentserver_ipc,
                     oc_documentserver_locks, oc_documentserver_sess,
                     oc_officeonline_locks, oc_officeonline_wopi,
                     oc_onlyoffice_filekey;

-- 28 configuration rows
DELETE FROM oc_appconfig
 WHERE appid IN ('onlyoffice', 'documentserver_community', 'officeonline');
DELETE FROM oc_preferences
 WHERE appid IN ('onlyoffice', 'documentserver_community', 'officeonline');
```

Plus 137 leftover files (23 MB) under
`<datadir>/appdata_<instanceid>/documentserver_community/`.

Worth knowing for the filecache work in section 1: `documentserver_community`
accounted for **276,225 filecache rows but only 137 files still on disk**. The
unpacked OnlyOffice distribution was deleted when the app went, but its index
entries survived in the stale storage. A quarter of the whole file index was
OnlyOffice debris, which is why those rows do *not* come back on a rescan.

**Activity log without a retention policy.** `oc_activity` held 128,290 rows
(90 MB) with `activity_expire_days` unset, which means unlimited.

**Fragmentation** elsewhere: ~61 MB of free space spread across other tables,
reclaimable with `OPTIMIZE TABLE`.

---

## 7. MariaDB itself

Separate from the data, two things were wrong on the rehearsal host and are
worth checking on the production one.

**Slow query log configured but silently disabled.** `slow_query_log = ON` with
`slow_query_log_file = /var/log/mariadb/slow.log`, but MariaDB does not create
the directory. It logs one error at startup and then runs with slow logging off
for the life of the process:

```
[ERROR] Could not use /var/log/mariadb/slow.log for logging (error 2).
Turning logging off for the whole duration of the MariaDB server process.
```

Fixed in `roles/next_mariadb` — the directory is created with SELinux type
`mysqld_log_t`, plus a logrotate snippet.

**`mysql_secure_installation` leftovers.** Two anonymous accounts (empty user
name, no password, `USAGE` only) and an empty `test` database. Also handled by
the role now, on every run rather than only at install time.

**`skip_name_resolve` was off**, so every pod connection triggered a reverse DNS
lookup that cannot succeed for a `10.42.x` address — 25 warnings in two hours,
plus latency on every connect. Safe to enable once the anonymous account granted
by hostname is gone; all remaining accounts are matched by IP or connect over
the unix socket.

**systemd sandboxing.** The service scored 8.6 on `systemd-analyze security`
(higher is worse). A drop-in brought it to **1.4**. Unlike sshd, MariaDB starts
no user sessions, so sandboxing it restricts only the database — see
`roles/next_mariadb/files/systemd-hardening.conf` for why each setting is safe,
including the two that must *not* be set (`ProcSubset=pid` breaks startup, and
`RestrictAddressFamilies` must keep `AF_NETLINK` while name resolution is on).

---

## 8. Is the cleanup worth doing? Measured, not assumed

Short answer: **do it once, during the cutover, and never again as a separate
maintenance job.** It buys nothing in day-to-day operation.

The intuition is that a smaller database means less RAM and more speed. Neither
holds here, and the numbers say why:

```
innodb_buffer_pool_size  : 512 MB    <- a FIXED allocation
buffer pool pages total  : 32,448
              ... free   : 17,104    <- 53 % never used
read requests served     : 104,253,701
      ... from disk      : 114,182
hit rate                 : 99.89 %
MariaDB process RSS      : 911 MB
host RAM                 : 23.7 GB total, 18.8 GB available
```

**RAM does not change.** The buffer pool is a fixed allocation. MariaDB does not
use more because the database is large, and will not use less when it shrinks.

**Query speed does not change either.** More than half the buffer pool is idle
and 99.89 % of reads already come from memory. There is no cache pressure to
relieve. The rows removed were preview-index entries that day-to-day operations
never touch; the genuinely hot working set — user files, shares, sessions — was
always small and always resident.

Where the reduction *is* measurable is in operations that walk the whole table:

- **Backups**: ~932 MB → ~400 MB, so faster dumps and smaller archives
- **`occ files:scan --all`**
- **Major-version upgrades**, which rewrite parts of `oc_filecache`
- For scale: `files:cleanup` took 57 s for 553,715 rows

That is the argument for folding it into the migration: the new instance starts
with a clean index, and every future major upgrade works on ~150k rows instead
of ~1M. It is not an argument for touching a healthy production database on a
quiet Sunday — each of these steps modifies the central file index, and the
rehearsal turned up an active share hanging off a supposedly dead storage.

The unambiguous dead weight (`oc_maps_photos` 33 MB, the OnlyOffice tables
10 MB, `oc_activity` without a retention policy) can be removed independently at
any time. Nothing depends on it.

---

## 9. Pre-flight checklist for the production cutover

- [ ] `mysqldump` of the restored database **before** any cleanup, verified to
      contain `INSERT INTO \`oc_filecache\`` and the expected table count
- [ ] List `local::` storages and identify the live one by highest `fileid`
- [ ] For each stale storage: check mounts, shares, and **`files/` rows**
- [ ] Note control values: user files, shares, users
- [ ] Delete dead shares → delete storage row → `occ files:cleanup`
- [ ] `OPTIMIZE TABLE oc_filecache` (needs free disk ≈ table size, locks table)
- [ ] Orphaned previews: `rm -rf <datadir>/appdata_<instanceid>/preview`
      rather than re-indexing them - it is a cache, and the rescan puts
      ~500k rows straight back into the table you just cleaned
- [ ] Re-verify control values and reachability
- [ ] Set `activity_expire_days` before the activity table grows again
