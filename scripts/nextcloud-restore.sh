#!/usr/bin/env bash
# Nextcloud K3s restore script.
#
# Usage:
#   ./nextcloud-restore.sh <environment>
#   BACKUP_DIR=/tmp/cvjm-3d ./nextcloud-restore.sh cvjm   # an older state from rdiff
#
# Environments:  test | sofie | cvjm
#
# Reads the layout written by scripts/nextcloud-backup/ (nc_backup_lib.sh):
#   /data/backup/nextcloud-data/<env>/{www,data,db/<db>_<date>_<time>.sql.gz}
# and restores the NEWEST dump in db/. For an older state, first restore it
# from rdiff (see scripts/nextcloud-backup/README.md) and point BACKUP_DIR there.
#
# Typical workflow after wiping and rebuilding a server:
#   1. ansible-playbook nextcloud-k3s.yml --limit <env>
#   2. ./nextcloud-restore.sh <env>
#   3. ansible-playbook nextcloud-k3s.yml --limit <env>
#      (re-applies occ settings: trusted_domains, WOPI, app config)
#
# What is NOT restored:
#   - Redis cache (ephemeral, rebuilt automatically)
#   - Let's Encrypt certificates (reissued automatically by cert-manager)
#
# K3s hosts only. A native install (e.g. sofie before its migration) is
# refused - restore it by hand, see scripts/nextcloud-backup/README.md.

set -euo pipefail

ENV="${1:-}"
if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment>"
  echo "       environments: test | sofie | cvjm"
  exit 1
fi

case "$ENV" in
  test)  DB_NAME="test_nextcloud"  ;;
  sofie) DB_NAME="sofie_nextcloud" ;;
  cvjm)  DB_NAME="cvjm_nextcloud"  ;;
  *)
    echo "Unknown environment: $ENV"
    echo "Valid values: test | sofie | cvjm"
    exit 1
    ;;
esac
REMOTE_USER="root"
BACKUP_DIR="${BACKUP_DIR:-/data/backup/nextcloud-data/$ENV}"

# Address and SSH port come from the (gitignored) Ansible inventory, so no real
# address is ever hardcoded in this tracked file - see lib/inventory-lookup.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/inventory-lookup.sh"
inventory_lookup "$ENV"

DUMP="$(ls -1t "$BACKUP_DIR/db/${DB_NAME}_"*.sql.gz 2>/dev/null | head -n 1 || true)"
if [[ -z "$DUMP" || ! -d "$BACKUP_DIR/www" || ! -d "$BACKUP_DIR/data" ]]; then
  echo "Error: no complete backup under $BACKUP_DIR (need www/, data/, db/${DB_NAME}_*.sql.gz)"
  exit 1
fi
gzip -t "$DUMP" || { echo "Error: $DUMP is not a valid gzip file"; exit 1; }

# ---------------------------------------------------------------------------
# Fixed values (same for all servers)
# ---------------------------------------------------------------------------
SSH_KEY="$HOME/.ssh/id_rsa"
REMOTE_WWW_DIR="/srv/nextcloud-www"
REMOTE_DATA_DIR="/data"
NAMESPACE="nextcloud"
DEPLOYMENT="nextcloud"

SSH_CMD="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR $REMOTE_USER@$REMOTE_HOST"
# Note: RSYNC_E must be a quoted string passed via eval-safe expansion.
# Do NOT use a bare variable like RSYNC_SSH="-e ssh -i KEY -p PORT ..." –
# unquoted expansion splits the SSH args into rsync source paths and uploads
# local files (including the SSH key itself) to the remote. Always inline -e.
RSYNC_E="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR"
OCC="k3s kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -c nextcloud-fpm -- runuser -u www-data -- php /var/www/html/occ"

$SSH_CMD "command -v k3s >/dev/null" || {
  echo "Error: $REMOTE_HOST has no K3s - native install, restore by hand (see README)."
  exit 1
}

# ---------------------------------------------------------------------------

echo "=== Nextcloud Restore: $ENV ($REMOTE_HOST) ==="
echo "    Source: $BACKUP_DIR"
echo "    Dump:   $(basename "$DUMP")   Data as of: $(cat "$BACKUP_DIR/last-success" 2>/dev/null || echo unknown)"
echo "    This OVERWRITES code, data and database on $REMOTE_HOST."
read -r -p "    Type the environment name ($ENV) to continue: " answer
[[ "$answer" == "$ENV" ]] || { echo "Aborted."; exit 1; }

echo "[1/8] Enabling maintenance mode ..."
$SSH_CMD "$OCC maintenance:mode --on" || true

echo "[2/8] Scaling down Nextcloud deployment ..."
$SSH_CMD "k3s kubectl scale deployment/$DEPLOYMENT -n $NAMESPACE --replicas=0"
$SSH_CMD "k3s kubectl wait pod \
  --selector app=$DEPLOYMENT -n $NAMESPACE \
  --for=delete --timeout=60s" 2>/dev/null || true

echo "[3/8] Transferring app files to $REMOTE_WWW_DIR ..."
rsync -a --delete --exclude "data/" \
  -e "$RSYNC_E" \
  "$BACKUP_DIR/www/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_WWW_DIR/"

echo "[4/8] Transferring user data to $REMOTE_DATA_DIR ..."
rsync -a --delete \
  -e "$RSYNC_E" \
  "$BACKUP_DIR/data/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DATA_DIR/"

echo "[5/8] Restoring database dump $(basename "$DUMP") ..."
zcat "$DUMP" | $SSH_CMD "mysql $DB_NAME"

echo "[6/8] Fixing ownership (www-data = uid 33) ..."
$SSH_CMD "chown -R 33:33 $REMOTE_WWW_DIR $REMOTE_DATA_DIR"
$SSH_CMD "chmod 0755 $REMOTE_WWW_DIR && chmod 0770 $REMOTE_DATA_DIR"

echo "[7/8] Scaling Nextcloud back up ..."
$SSH_CMD "k3s kubectl scale deployment/$DEPLOYMENT -n $NAMESPACE --replicas=1"
$SSH_CMD "k3s kubectl wait pod \
  --selector app=$DEPLOYMENT -n $NAMESPACE \
  --for=condition=ready --timeout=300s"

echo "[8/8] Rebuilding file index and disabling maintenance mode ..."
$SSH_CMD "$OCC maintenance:mode --off"
$SSH_CMD "$OCC maintenance:data-fingerprint"
$SSH_CMD "$OCC files:scan --all"

echo ""
echo "Restore complete."
echo ""
echo "Next step – re-apply Ansible config (trusted_domains, WOPI, occ settings):"
echo "  ansible-playbook nextcloud-k3s.yml --limit $ENV --ask-vault-pass"
