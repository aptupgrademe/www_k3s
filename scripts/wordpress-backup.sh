#!/bin/bash
# WordPress K3s backup script (www.apt-upgrade.me).
#
# Usage:
#   ./wordpress-backup.sh
#
# What is backed up:
#   wordpress/  – WordPress app files  (/srv/wordpress-www)
#   db.sql      – MariaDB dump from K3s pod (--single-transaction)
#
# Note: unlike Nextcloud, the MariaDB here runs as a K3s pod.
# The dump is created via kubectl exec into the mariadb container.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REMOTE_USER="root"
REMOTE_HOST="217.154.101.78"
REMOTE_SSH_PORT=10022
SSH_KEY="$HOME/.ssh/id_rsa"

LOCAL_BACKUP_DIR="/data/wordpress/www.apt-upgrade.me"
REMOTE_WWW_DIR="/srv/wordpress-www"
REMOTE_DB_NAME="wordpress_db"
NAMESPACE="wordpress"

LOCAL_WWW_DIR="$LOCAL_BACKUP_DIR/wordpress"

SSH_CMD="ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR $REMOTE_USER@$REMOTE_HOST"

# ---------------------------------------------------------------------------

echo "=== WordPress Backup: www.apt-upgrade.me ($REMOTE_HOST) ==="
mkdir -p "$LOCAL_WWW_DIR"

echo "[1/4] Enabling WordPress maintenance mode ..."
# WP-CLI is downloaded by the init container to /var/www/html/wp-cli.phar
$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /var/www/html/wp-cli.phar maintenance-mode activate \
  --path=/var/www/html --allow-root" > /dev/null

echo "[2/4] Creating database dump from MariaDB pod ..."
# MariaDB runs as a K3s pod; MARIADB_ROOT_PASSWORD is injected via K8s Secret.
# We reference it directly in the shell command inside the container.
$SSH_CMD "k3s kubectl exec deployment/mariadb -n $NAMESPACE -c mariadb -- \
  sh -c 'mysqldump --single-transaction $REMOTE_DB_NAME \
    -u root -p\"\$MARIADB_ROOT_PASSWORD\" 2>/dev/null'" \
  > "$LOCAL_BACKUP_DIR/db.sql"

echo "[3/4] Backing up WordPress files from $REMOTE_WWW_DIR ..."
rsync -az --delete \
  -e "ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_WWW_DIR/" "$LOCAL_WWW_DIR/"

echo "[4/4] Disabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /var/www/html/wp-cli.phar maintenance-mode deactivate \
  --path=/var/www/html --allow-root" > /dev/null

echo ""
echo "Backup complete → $LOCAL_BACKUP_DIR"
echo "  $(du -sh "$LOCAL_BACKUP_DIR" | cut -f1)  total"
