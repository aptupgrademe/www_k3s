#!/usr/bin/env bash
# WordPress K3s restore script (www.apt-upgrade.me).
#
# Usage:
#   ./wordpress-restore.sh
#
# Typical workflow after wiping and rebuilding the server:
#   1. ansible-playbook blog.yml --limit www.apt-upgrade.me --ask-vault-pass
#   2. ./wordpress-restore.sh
#   3. ansible-playbook blog.yml --limit www.apt-upgrade.me --ask-vault-pass
#      (re-applies WordPress config, plugins, permalinks)
#
# Note: unlike Nextcloud, the MariaDB here runs as a K3s pod.
# The database restore drops the existing MariaDB data dir, lets the pod
# reinitialize, then imports the SQL dump via kubectl exec.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REMOTE_USER="root"
REMOTE_HOST="217.154.101.78"
REMOTE_SSH_PORT=10022
SSH_KEY="$HOME/.ssh/id_rsa"

BACKUP_DIR="/data/wordpress/www.apt-upgrade.me"
REMOTE_WWW_DIR="/srv/wordpress-www"
REMOTE_DB_DIR="/srv/wordpress-db"    # HostPath for MariaDB data files
REMOTE_DB_NAME="wordpress_db"
NAMESPACE="wordpress"

SSH_CMD="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR $REMOTE_USER@$REMOTE_HOST"
RSYNC_SSH="-e ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR"

# ---------------------------------------------------------------------------

if [[ ! -f "$BACKUP_DIR/db.sql" ]]; then
  echo "Error: Backup not found at $BACKUP_DIR"
  echo "Run ./wordpress-backup.sh first."
  exit 1
fi

echo "=== WordPress Restore: www.apt-upgrade.me ($REMOTE_HOST) ==="
echo "    Source: $BACKUP_DIR"

echo "[1/9] Enabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /var/www/html/wp-cli.phar maintenance-mode activate \
  --path=/var/www/html --allow-root" || true

echo "[2/9] Scaling down WordPress and MariaDB deployments ..."
$SSH_CMD "k3s kubectl scale deployment/wordpress deployment/mariadb \
  -n $NAMESPACE --replicas=0"
$SSH_CMD "k3s kubectl wait pod -n $NAMESPACE \
  --selector 'app in (wordpress,mariadb)' \
  --for=delete --timeout=90s" 2>/dev/null || true

echo "[3/9] Transferring WordPress files to $REMOTE_WWW_DIR ..."
rsync -a --delete \
  $RSYNC_SSH \
  "$BACKUP_DIR/wordpress/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_WWW_DIR/"

echo "[4/9] Clearing MariaDB data dir (forces reinitialisation on next start) ..."
# The MariaDB pod reinitialises from MARIADB_* env vars (K8s Secret) when the
# data dir is empty – it recreates the wordpress_db database and user.
$SSH_CMD "rm -rf $REMOTE_DB_DIR/* && echo 'data dir cleared'"

echo "[5/9] Starting MariaDB (initialises fresh database) ..."
$SSH_CMD "k3s kubectl scale deployment/mariadb -n $NAMESPACE --replicas=1"
$SSH_CMD "k3s kubectl wait deployment/mariadb -n $NAMESPACE \
  --for=condition=available --timeout=120s"
# Extra wait for MariaDB to be fully ready inside the container
sleep 10

echo "[6/9] Importing database dump ..."
# Copy dump to the server, then pipe into the mariadb container
scp -i "$SSH_KEY" -P $REMOTE_SSH_PORT "$BACKUP_DIR/db.sql" \
  "$REMOTE_USER@$REMOTE_HOST:/tmp/wp_restore.sql"
$SSH_CMD "k3s kubectl exec deployment/mariadb -n $NAMESPACE -c mariadb -- \
  sh -c 'mysql $REMOTE_DB_NAME \
    -u root -p\"\$MARIADB_ROOT_PASSWORD\" < /tmp/wp_restore.sql' && \
  rm -f /tmp/wp_restore.sql"

echo "[7/9] Fixing file ownership (www-data = uid 33) ..."
$SSH_CMD "chown -R 33:33 $REMOTE_WWW_DIR && chmod 0755 $REMOTE_WWW_DIR"

echo "[8/9] Starting WordPress ..."
$SSH_CMD "k3s kubectl scale deployment/wordpress -n $NAMESPACE --replicas=1"
$SSH_CMD "k3s kubectl wait deployment/wordpress -n $NAMESPACE \
  --for=condition=available --timeout=180s"

echo "[9/9] Disabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /var/www/html/wp-cli.phar maintenance-mode deactivate \
  --path=/var/www/html --allow-root"

echo ""
echo "Restore complete."
echo ""
echo "Next step – re-apply Ansible config (plugins, permalinks, settings):"
echo "  ansible-playbook blog.yml --limit www.apt-upgrade.me --ask-vault-pass"
echo ""
echo "Then verify at: https://www.apt-upgrade.me"
