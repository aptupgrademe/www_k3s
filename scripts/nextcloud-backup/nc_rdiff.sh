#!/bin/bash
# =============================================================================
# Versionierung aller Nextcloud-Sicherungen mit rdiff-backup.
#   Quelle: /data/backup/nextcloud-data/<instanz>  (nur die in INSTANCES, derzeit cvjm)
#   Ziel:   /data/backup/nextcloud-rdiff/  (Spiegel + rückwärts gespeicherte Diffs)
#
# Läuft per cron nach den Instanz-Backups. Wartet, bis keines davon mehr läuft
# (dieselben Lock-Dateien wie nc_backup_lib.sh), sonst würde ein halb
# aktualisierter Spiegel versioniert. Versionen älter als KEEP werden entfernt.
#
# Wiederherstellen eines alten Stands, z. B. eine Datei von vor 3 Tagen:
#   rdiff-backup list increments /data/backup/nextcloud-rdiff
#   rdiff-backup --api-version 201 restore --at 3D \
#       /data/backup/nextcloud-rdiff/cvjm/data/<pfad> /tmp/restore-<name>
# =============================================================================

set -o pipefail
SRC=/data/backup/nextcloud-data
DST=/data/backup/nextcloud-rdiff
KEEP=${KEEP:-30D}
INSTANCES=${INSTANCES:-"cvjm"}
LOGDIR=/data/backup/nextcloud/logs
KEEP_LOGS=30
RDIFF="rdiff-backup --api-version 201"

mkdir -p "$DST" "$LOGDIR"
LOG="$LOGDIR/rdiff_$(date +%Y-%m-%d_%H%M).log"
exec >>"$LOG" 2>&1
log()  { echo "$(date '+%F %T') $*"; }
fail() { log "FEHLER: $*"; log "=== rdiff ABGEBROCHEN ==="; exit 1; }

exec 7>/tmp/nc-rdiff.lock
flock -n 7 || { log "rdiff läuft bereits – übersprungen"; exit 0; }

# Auf laufende Instanz-Backups warten (max. 3 h), Locks dann halten.
fd=10
for inst in $INSTANCES; do
    eval "exec $fd>/tmp/nc-backup-$inst.lock"
    flock -w 10800 $fd || fail "Backup $inst läuft seit über 3 h – rdiff übersprungen"
    fd=$((fd + 1))
done

log "=== rdiff $SRC -> $DST start ==="
# Nur die gelisteten Instanzen versionieren, alle anderen Ordner in $SRC ignorieren.
INCLUDES=()
for inst in $INSTANCES; do INCLUDES+=(--include "$SRC/$inst"); done
$RDIFF backup "${INCLUDES[@]}" --exclude "**" "$SRC" "$DST" || fail "rdiff-backup backup"
log "Versionen älter als $KEEP entfernen ..."
$RDIFF remove increments --older-than "$KEEP" "$DST" || log "Hinweis: remove increments meldete einen Fehler"
$RDIFF list increments "$DST" | tail -n 3
ls -1t "$LOGDIR"/rdiff_*.log | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -f
log "=== rdiff erfolgreich (${SECONDS}s) ==="
