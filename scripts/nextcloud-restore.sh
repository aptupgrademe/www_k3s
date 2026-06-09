#!/usr/bin/env bash
# Nextcloud K3s restore script.
#
# Usage:
#   ./nextcloud-restore.sh <environment>
#
# Environments:  test | sofie | cvjm
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
    BACKUP_DIR="/data/nextcloud/test"
    DB_NAME="test_nextcloud"
    ;;
  sofie)
    REMOTE_USER="root"
    REMOTE_HOST="CHANGE_ME"     # set ansible_host in inventory/hosts.yml
    REMOTE_SSH_PORT=10022
    BACKUP_DIR="/data/nextcloud/sofie"
    DB_NAME="sofie_nextcloud"
    ;;
  cvjm)
    REMOTE_USER="root"
    REMOTE_HOST="CHANGE_ME"     # set ansible_host in inventory/hosts.yml
    REMOTE_SSH_PORT=10022
    BACKUP_DIR="/data/nextcloud/cvjm"
    DB_NAME="cvjm_nextcloud"
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

if [[ ! -f "$BACKUP_DIR/db.sql" ]]; then
  echo "Error: Backup not found at $BACKUP_DIR"
  echo "Run ./nextcloud-backup.sh $ENV first."
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

SSH_CMD="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR $REMOTE_USER@$REMOTE_HOST"
# Note: RSYNC_E must be a quoted string passed via eval-safe expansion.
# Do NOT use a bare variable like RSYNC_SSH="-e ssh -i KEY -p PORT ..." –
# unquoted expansion splits the SSH args into rsync source paths and uploads
# local files (including the SSH key itself) to the remote. Always inline -e.
RSYNC_E="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR"

# ---------------------------------------------------------------------------

echo "=== Nextcloud Restore: $ENV ($REMOTE_HOST) ==="
echo "    Source: $BACKUP_DIR"

echo "[1/8] Enabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -c nextcloud-fpm -- \
  runuser -u www-data -- php /var/www/html/occ maintenance:mode --on" || true

echo "[2/8] Scaling down Nextcloud deployment ..."
$SSH_CMD "k3s kubectl scale deployment/$DEPLOYMENT -n $NAMESPACE --replicas=0"
$SSH_CMD "k3s kubectl wait pod \
  --selector app=$DEPLOYMENT -n $NAMESPACE \
  --for=delete --timeout=60s" 2>/dev/null || true

echo "[3/8] Transferring app files to $REMOTE_WWW_DIR ..."
rsync -a --delete --exclude "data/" \
  -e "$RSYNC_E" \
  "$BACKUP_DIR/nextcloud/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_WWW_DIR/"

echo "[4/8] Transferring user data to $REMOTE_DATA_DIR ..."
rsync -a --delete \
  -e "$RSYNC_E" \
  "$BACKUP_DIR/data/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DATA_DIR/"

echo "[5/8] Restoring database dump ..."
scp -i "$SSH_KEY" -P $REMOTE_SSH_PORT "$BACKUP_DIR/db.sql" \
  "$REMOTE_USER@$REMOTE_HOST:/tmp/nc_restore.sql"
$SSH_CMD "mysql $DB_NAME < /tmp/nc_restore.sql && rm /tmp/nc_restore.sql"

echo "[6/8] Fixing ownership (www-data = uid 33) ..."
$SSH_CMD "chown -R 33:33 $REMOTE_WWW_DIR $REMOTE_DATA_DIR"
$SSH_CMD "chmod 0755 $REMOTE_WWW_DIR && chmod 0770 $REMOTE_DATA_DIR"

echo "[7/8] Scaling Nextcloud back up ..."
$SSH_CMD "k3s kubectl scale deployment/$DEPLOYMENT -n $NAMESPACE --replicas=1"
$SSH_CMD "k3s kubectl wait pod \
  --selector app=$DEPLOYMENT -n $NAMESPACE \
  --for=condition=ready --timeout=300s"

echo "[8/8] Rebuilding file index and disabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -c nextcloud-fpm -- \
  runuser -u www-data -- php /var/www/html/occ maintenance:mode --off"
$SSH_CMD "k3s kubectl exec deployment/$DEPLOYMENT -n $NAMESPACE -c nextcloud-fpm -- \
  runuser -u www-data -- php /var/www/html/occ files:scan --all"

echo ""
echo "Restore complete."
echo ""
echo "Next step – re-apply Ansible config (trusted_domains, WOPI, occ settings):"
echo "  ansible-playbook nextcloud-k3s.yml --limit $ENV --ask-vault-pass"
