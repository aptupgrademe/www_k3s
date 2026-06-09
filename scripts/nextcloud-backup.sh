#!/bin/bash
# Nextcloud K3s backup script.
#
# Usage:
#   ./nextcloud-backup.sh <environment>
#
# Environments:  test | sofie | cvjm
#
# What is backed up:
#   nextcloud/  – Nextcloud app files  (/srv/nextcloud-www)
#   data/       – User data            (/data)
#   db.sql      – MariaDB dump         (consistent, --single-transaction)
#
# Note: CVJM and Sofie IPs must be set in inventory/hosts.yml before use.

set -euo pipefail

ENV="${1:-}"
if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <environment>"
  echo "       environments: test | sofie | cvjm"
  exit 1
fi

# ---------------------------------------------------------------------------
# Per-environment configuration
# ---------------------------------------------------------------------------
case "$ENV" in
  test)
    REMOTE_USER="root"
    REMOTE_HOST="82.165.165.230"
    REMOTE_SSH_PORT=22          # change to 10022 once common_ssh is applied
    LOCAL_BACKUP_DIR="/data/nextcloud/test"
    REMOTE_DB_NAME="test_nextcloud"
    ;;
  sofie)
    REMOTE_USER="root"
    REMOTE_HOST="CHANGE_ME"     # set ansible_host in inventory/hosts.yml
    REMOTE_SSH_PORT=10022
    LOCAL_BACKUP_DIR="/data/nextcloud/sofie"
    REMOTE_DB_NAME="sofie_nextcloud"
    ;;
  cvjm)
    REMOTE_USER="root"
    REMOTE_HOST="CHANGE_ME"     # set ansible_host in inventory/hosts.yml
    REMOTE_SSH_PORT=10022
    LOCAL_BACKUP_DIR="/data/nextcloud/cvjm"
    REMOTE_DB_NAME="cvjm_nextcloud"
    ;;
  *)
    echo "Unknown environment: $ENV"
    echo "Valid values: test | sofie | cvjm"
    exit 1
    ;;
esac

if [[ "$REMOTE_HOST" == "CHANGE_ME" ]]; then
  echo "Error: IP for '$ENV' is not configured yet."
  echo "Set ansible_host in inventory/hosts.yml and fill in host_vars/$ENV/vars.yml."
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixed values (same for all servers)
# ---------------------------------------------------------------------------
SSH_KEY="$HOME/.ssh/id_rsa"
REMOTE_WWW_DIR="/srv/nextcloud-www"
REMOTE_DATA_DIR="/data"
NAMESPACE="nextcloud"
DEPLOYMENT="nextcloud"

LOCAL_WEB_DIR="$LOCAL_BACKUP_DIR/nextcloud"
LOCAL_DATA_DIR="$LOCAL_BACKUP_DIR/data"

SSH_CMD="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR $REMOTE_USER@$REMOTE_HOST"

# ---------------------------------------------------------------------------

echo "=== Nextcloud Backup: $ENV ($REMOTE_HOST) ==="
mkdir -p "$LOCAL_WEB_DIR" "$LOCAL_DATA_DIR"

echo "[1/5] Enabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -c nextcloud-fpm -- \
  runuser -u www-data -- php /var/www/html/occ maintenance:mode --on" > /dev/null

echo "[2/5] Creating database dump ..."
$SSH_CMD "mysqldump --single-transaction $REMOTE_DB_NAME" \
  > "$LOCAL_BACKUP_DIR/db.sql"

echo "[3/5] Backing up app files from $REMOTE_WWW_DIR ..."
rsync -az --delete \
  -e "ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_WWW_DIR/" "$LOCAL_WEB_DIR/"

echo "[4/5] Backing up user data from $REMOTE_DATA_DIR ..."
rsync -az --delete \
  -e "ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DATA_DIR/" "$LOCAL_DATA_DIR/"

echo "[5/5] Disabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -c nextcloud-fpm -- \
  runuser -u www-data -- php /var/www/html/occ maintenance:mode --off" > /dev/null

echo ""
echo "Backup complete → $LOCAL_BACKUP_DIR"
echo "  $(du -sh "$LOCAL_BACKUP_DIR" | cut -f1)  total"
