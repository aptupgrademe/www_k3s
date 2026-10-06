#!/bin/bash
# =============================================================================
# Versionierung der WordPress-Sicherungen mit rdiff-backup.
#   Quelle: /data/backup/wordpress-data/<name>   (nur die in INSTANCES)
#   Ziel:   /data/backup/wordpress-rdiff/        (Spiegel + rückwärts gespeicherte Diffs)
# Wartet auf laufende Backups (dieselben Lock-Dateien wie wp_backup_lib.sh).
#
# Wiederherstellen eines alten Stands, z. B. von vor 3 Tagen:
#   rdiff-backup --api-version 201 list increments /data/backup/wordpress-rdiff
#   rdiff-backup --api-version 201 restore --at 3D \
#       /data/backup/wordpress-rdiff/blog/www/wp-content/uploads /tmp/restore-uploads
# =============================================================================

set -o pipefail
# SRC darf auch entfernt sein: SRC=root@hp3::/storage (rdiff-backup über SSH,
# dafür braucht der Quellrechner dieselbe rdiff-backup-Version).
SRC=${SRC:-/data/backup/wordpress-data}
SRC_HOST=; SRC_PATH=$SRC
case "$SRC" in *::*) SRC_HOST=${SRC%%::*}; SRC_PATH=${SRC#*::} ;; esac
DST=${DST:-/data/backup/wordpress-rdiff}
KEEP=${KEEP:-30D}
INSTANCES=${INSTANCES:-"blog"}
LOGDIR=${LOGDIR:-/data/backup/wordpress/logs}
KEEP_LOGS=30
RDIFF="rdiff-backup --api-version 201"

umask 077
mkdir -p "$DST" "$LOGDIR"
LOG="$LOGDIR/rdiff_$(date +%Y-%m-%d_%H%M).log"
exec >>"$LOG" 2>&1
log()  { echo "$(date '+%F %T') $*"; }
fail() { log "FEHLER: $*"; log "=== rdiff ABGEBROCHEN ==="; exit 1; }

exec 7>/tmp/wp-rdiff.lock
flock -n 7 || { log "rdiff läuft bereits – übersprungen"; exit 0; }
if [ -z "$SRC_HOST" ]; then
    fd=10
    for inst in $INSTANCES; do
        eval "exec $fd>/tmp/wp-backup-$inst.lock"
        flock -w 10800 $fd || fail "Backup $inst läuft seit über 3 h – rdiff übersprungen"
        fd=$((fd + 1))
    done
else
    # Entfernte Quelle: auf dem Quellrechner auf laufende Backups warten und prüfen, dass
    # jede Instanz erfolgreich gesichert und nicht leer ist (rdiff gegen eine leere Quelle
    # würde alles als gelöscht verbuchen).
    for inst in $INSTANCES; do
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$SRC_HOST" \
            "flock -w 10800 /tmp/wp-backup-$inst.lock true && test -s '$SRC_PATH/$inst/last-success' && test -n \"\$(ls -A '$SRC_PATH/$inst/www' 2>/dev/null)\"" \
            || fail "Quelle $SRC_HOST:$SRC_PATH/$inst nicht bereit (Backup läuft, fehlgeschlagen oder leer)"
    done
fi

log "=== rdiff $SRC -> $DST start ==="
INCLUDES=()
for inst in $INSTANCES; do INCLUDES+=(--include "$SRC_PATH/$inst"); done
$RDIFF backup "${INCLUDES[@]}" --exclude "**" "$SRC" "$DST" || fail "rdiff-backup backup"
if ! OUT=$($RDIFF remove increments --older-than "$KEEP" "$DST" 2>&1); then
    if grep -q "No increment is older" <<<"$OUT"; then log "Keine Versionen älter als $KEEP – nichts zu entfernen"
    else echo "$OUT"; log "Hinweis: remove increments meldete einen Fehler"; fi
else [ -n "$OUT" ] && echo "$OUT"; fi
$RDIFF list increments "$DST" | tail -n 3
ls -1t "$LOGDIR"/rdiff_*.log | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -f
log "=== rdiff erfolgreich (${SECONDS}s) ==="
