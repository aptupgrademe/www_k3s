#!/bin/bash
# =============================================================================
# WordPress-Backup (K3s) – gemeinsame Logik. Wird von <name>_backup.sh
# eingebunden, nicht direkt aufrufen. Zieht per SSH (root) auf diesen Rechner:
#
#   /data/backup/wordpress-data/<NAME>/db/    DB-Dumps (gzip, die letzten KEEP_DUMPS)
#   /data/backup/wordpress-data/<NAME>/www/   hostPath des WordPress-Volumes
#                                             (Core, wp-content: Uploads, Plugins,
#                                             Themes, Sprachen; wp-config.php)
#
# Gleicher Ablauf wie das Nextcloud-Backup, ohne Wartungsmodus:
#   1. rsync www        – überträgt fast alles
#   2. DB-Dump          – mariadb-dump im MariaDB-Pod, --single-transaction
#   3. rsync www        – nur noch die Änderungen seit Schritt 1
#
# Kein Passwort hier: der Dump läuft per kubectl exec im MariaDB-Container und
# liest das Root-Passwort aus der dort eingehängten Secret-Datei.
# Erfolg schreibt /var/lib/wordpress-backup/last-success auf dem Server
# (Monit-Check wp_backup warnt, wenn er zu alt wird) und <NAME>/last-success.
# =============================================================================

set -o pipefail
: "${NAME:?}" "${REMOTE_HOST:?}"
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_PORT=${REMOTE_PORT:-10022}
REMOTE_WWW=${REMOTE_WWW:-/srv/wordpress-www}
K8S_NS=${K8S_NS:-wordpress}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_rsa}
KEEP_DUMPS=${KEEP_DUMPS:-14}
KEEP_LOGS=${KEEP_LOGS:-30}
REMOTE_STAMP=${REMOTE_STAMP:-1}

BASE=/data/backup/wordpress-data/$NAME
LOGDIR=/data/backup/wordpress/logs
TS=$(date +%Y-%m-%d_%H%M)
SSH="ssh -i $SSH_KEY -p $REMOTE_PORT -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30"
TARGET="$REMOTE_USER@$REMOTE_HOST"

umask 077   # wp-config.php und die Dumps enthalten Zugangsdaten
mkdir -p "$BASE/db" "$BASE/www" "$LOGDIR"
LOG="$LOGDIR/${NAME}_$TS.log"
exec >>"$LOG" 2>&1

log()  { echo "$(date '+%F %T') $*"; }
fail() { log "FEHLER: $*"; log "=== Backup $NAME ABGEBROCHEN ==="; exit 1; }

exec 9>"/tmp/wp-backup-$NAME.lock"
flock -n 9 || { log "läuft bereits – übersprungen"; exit 0; }

log "=== Backup $NAME start ($TARGET) ==="
for i in $(seq 1 90); do
    $SSH "$TARGET" true 2>/dev/null && break
    [ "$i" -eq 90 ] && fail "$REMOTE_HOST per SSH nicht erreichbar"
    sleep 10
done

sync_www() {
    log "rsync $REMOTE_WWW -> $BASE/www ..."
    rsync -rlptD --delete --delete-delay --partial --numeric-ids -h --stats \
        -e "$SSH" "$TARGET:$REMOTE_WWW/" "$BASE/www/" | grep -E "^(Number of (regular )?files|Total transferred|Total file size|Number of deleted)"
    local rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ] || fail "rsync (Exit $rc)"
    [ "$rc" -eq 24 ] && log "Hinweis: einige Dateien verschwanden während des Laufs (normal im Betrieb)"
    return 0
}

log "--- Durchgang 1: Dateien ---"
sync_www

# Einfache Anführungszeichen: die Variablen werden erst im Container ausgewertet.
DUMP="$BASE/db/wordpress_$TS.sql.gz"
log "--- DB-Dump ---"
DUMP_START=$SECONDS
$SSH "$TARGET" "k3s kubectl -n $K8S_NS exec deploy/mariadb -c mariadb -- sh -c 'MYSQL_PWD=\"\$(cat /etc/secrets/db-root-password)\" mariadb-dump -u root --single-transaction --quick --routines --events \"\$MARIADB_DATABASE\"' | gzip" > "$DUMP.part" \
    || fail "mariadb-dump fehlgeschlagen"
gzip -t "$DUMP.part" || fail "Dump ist kein gültiges gzip"
zcat "$DUMP.part" | tail -n 1 | grep -q "Dump completed" || fail "Dump unvollständig"
mv "$DUMP.part" "$DUMP"
log "DB-Dump ok: $(du -h "$DUMP" | cut -f1)"
ls -1t "$BASE/db/wordpress_"*.sql.gz | tail -n +$((KEEP_DUMPS + 1)) | xargs -r rm -f

log "--- Durchgang 2: Änderungen seit Durchgang 1 ---"
sync_www
log "Abstand Dump-Start -> Dateien final: $((SECONDS - DUMP_START)) s"

if [ "$REMOTE_STAMP" = 1 ]; then
    $SSH "$TARGET" "mkdir -p /var/lib/wordpress-backup && date '+%F %T' > /var/lib/wordpress-backup/last-success" \
        || log "Hinweis: Zeitstempel auf $REMOTE_HOST nicht geschrieben"
fi
date '+%F %T' > "$BASE/last-success"
ls -1t "$LOGDIR/${NAME}_"*.log | tail -n +$((KEEP_LOGS + 1)) | xargs -r rm -f
log "=== Backup $NAME erfolgreich (${SECONDS}s) ==="
