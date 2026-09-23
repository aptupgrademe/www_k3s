#!/bin/bash
# =============================================================================
# Nextcloud-Backup – gemeinsame Logik. Wird von <instanz>_backup.sh eingebunden,
# nicht direkt aufrufen. Zieht per SSH (root) von der Instanz auf diesen Rechner:
#
#   /data/backup/nextcloud-data/<NAME>/db/    DB-Dumps (gzip, die letzten KEEP_DUMPS)
#   /data/backup/nextcloud-data/<NAME>/www/   Web-Ordner (Code + config/config.php)
#   /data/backup/nextcloud-data/<NAME>/data/  Data-Ordner (inkl. Previews)
#
# Ablauf, bewusst OHNE Wartungsmodus (läuft per cron beim Start des PCs und
# tagsüber, eine Sperre würde Nutzer treffen):
#   1. rsync www + data   – überträgt fast alles, darf lange dauern
#   2. DB-Dump            – --single-transaction: konsistent, sperrt nichts
#   3. rsync www + data   – nur noch die Änderungen seit Schritt 1 (kurz)
# Dump und Dateien liegen so nur Sekunden bis wenige Minuten auseinander. Was
# sich in diesem kleinen Fenster ändert, gleicht nach einem Restore
# `occ files:scan --all` ab (macht scripts/nextcloud-restore.sh).
#
# Kein Passwort hier: mysqldump läuft als root über /root/.my.cnf der Instanz.
# Erfolg schreibt einen Zeitstempel nach /var/lib/nextcloud-backup/last-success
# auf der Instanz (Monit warnt, wenn er zu alt wird) und nach <NAME>/last-success.
# =============================================================================

set -o pipefail
: "${NAME:?}" "${REMOTE_HOST:?}" "${DB_NAME:?}" "${REMOTE_WWW:?}" "${REMOTE_DATA:?}"
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_PORT=${REMOTE_PORT:-10022}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_rsa}
KEEP_DUMPS=${KEEP_DUMPS:-14}
KEEP_LOGS=${KEEP_LOGS:-30}
# REMOTE_STAMP=0: nichts auf die Instanz schreiben (rein lesender Lauf, z. B. ohne Monit dort).
REMOTE_STAMP=${REMOTE_STAMP:-1}

BASE=/data/backup/nextcloud-data/$NAME
LOGDIR=/data/backup/nextcloud/logs
TS=$(date +%Y-%m-%d_%H%M)
# LogLevel=ERROR: kein Login-Banner der Server im Log, echte Fehler bleiben sichtbar.
SSH="ssh -i $SSH_KEY -p $REMOTE_PORT -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30"
TARGET="$REMOTE_USER@$REMOTE_HOST"

mkdir -p "$BASE/db" "$BASE/www" "$BASE/data" "$LOGDIR"
LOG="$LOGDIR/${NAME}_$TS.log"
exec >>"$LOG" 2>&1

log()  { echo "$(date '+%F %T') $*"; }
fail() { log "FEHLER: $*"; log "=== Backup $NAME ABGEBROCHEN ==="; exit 1; }

# Nur ein Lauf pro Instanz gleichzeitig (@reboot und Tageslauf können sich treffen).
exec 9>"/tmp/nc-backup-$NAME.lock"
flock -n 9 || { log "läuft bereits – übersprungen"; exit 0; }

log "=== Backup $NAME start ($TARGET) ==="

# Nach einem Reboot ist das Netz evtl. noch nicht da: bis 15 min auf SSH warten.
for i in $(seq 1 90); do
    $SSH "$TARGET" true 2>/dev/null && break
    [ "$i" -eq 90 ] && fail "$REMOTE_HOST per SSH nicht erreichbar"
    sleep 10
done

# -rlptD statt -a: als normaler Benutzer lassen sich Besitzer (www-data) nicht
# setzen. Beim Restore wieder auf www-data (33) setzen. Exit 24 ("Dateien
# während der Übertragung verschwunden") ist im laufenden Betrieb normal.
sync_dir() {
    local src=$1 dst=$2
    log "rsync $src -> $dst ..."
    rsync -rlptD --delete --delete-delay --partial --numeric-ids -h --stats \
        -e "$SSH" "$TARGET:$src/" "$dst/" | grep -E "^(Number of (regular )?files|Total transferred|Total file size|Number of deleted)"
    local rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ] || fail "rsync $src (Exit $rc)"
    [ "$rc" -eq 24 ] && log "Hinweis: einige Dateien verschwanden während des Laufs (normal im Betrieb)"
    return 0
}

# --- 1. Dateien, großer Durchgang --------------------------------------------
log "--- Durchgang 1: Dateien (Hauptlast) ---"
sync_dir "$REMOTE_WWW"  "$BASE/www"
sync_dir "$REMOTE_DATA" "$BASE/data"

# --- 2. Datenbank ------------------------------------------------------------
# Erst in .part schreiben und prüfen: ein abgebrochener Dump ersetzt nie einen guten.
DUMP="$BASE/db/${DB_NAME}_$TS.sql.gz"
log "--- DB-Dump $DB_NAME ---"
DUMP_START=$SECONDS
$SSH "$TARGET" "mysqldump --single-transaction --quick --routines --events $DB_NAME | gzip" > "$DUMP.part" \
    || fail "mysqldump fehlgeschlagen"
gzip -t "$DUMP.part" || fail "Dump ist kein gültiges gzip"
zcat "$DUMP.part" | tail -n 1 | grep -q "Dump completed" || fail "Dump unvollständig"
mv "$DUMP.part" "$DUMP"
log "DB-Dump ok: $(du -h "$DUMP" | cut -f1)"
ls -1t "$BASE/db/${DB_NAME}_"*.sql.gz | tail -n +$((KEEP_DUMPS + 1)) | xargs -r rm -f

# --- 3. Dateien, Nachzügler --------------------------------------------------
log "--- Durchgang 2: Änderungen seit Durchgang 1 ---"
sync_dir "$REMOTE_WWW"  "$BASE/www"
sync_dir "$REMOTE_DATA" "$BASE/data"
log "Abstand Dump-Start -> Dateien final: $((SECONDS - DUMP_START)) s"

# --- 4. Erfolg festhalten ----------------------------------------------------
if [ "$REMOTE_STAMP" = 1 ]; then
    $SSH "$TARGET" "mkdir -p /var/lib/nextcloud-backup && date '+%F %T' > /var/lib/nextcloud-backup/last-success" \
        || log "Hinweis: Zeitstempel auf $REMOTE_HOST nicht geschrieben"
fi
date '+%F %T' > "$BASE/last-success"
ls -1t "$LOGDIR/${NAME}_"*.log | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -f
log "=== Backup $NAME erfolgreich (${SECONDS}s) ==="
