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
# Address and SSH port come from the (gitignored) Ansible inventory, so no real
# address is ever hardcoded in this tracked file - see lib/inventory-lookup.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/inventory-lookup.sh"
inventory_lookup "www.apt-upgrade.me"
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
# WP-CLI ships inside the image at /usr/local/lib/wp-cli/wp-cli.phar.
$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /usr/local/lib/wp-cli/wp-cli.phar maintenance-mode activate \
  --path=/var/www/html --allow-root" > /dev/null

# With set -e, any failure below would leave the site in maintenance mode -
# i.e. a failed backup would also take the blog offline. Always lift it again.
trap '$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /usr/local/lib/wp-cli/wp-cli.phar maintenance-mode deactivate \
  --path=/var/www/html --allow-root" > /dev/null 2>&1 || true' EXIT

echo "[2/4] Creating database dump from MariaDB pod ..."
# MariaDB runs as a K3s pod. The image takes the root password as a *_FILE
# secret mount, not as a plain environment variable - reading the env var
# instead authenticates with an empty password and the dump comes back empty.
$SSH_CMD "k3s kubectl exec deployment/mariadb -n $NAMESPACE -c mariadb -- \
  sh -c 'mysqldump --single-transaction $REMOTE_DB_NAME \
    -u root -p\"\$(cat \$MARIADB_ROOT_PASSWORD_FILE)\"'" \
  > "$LOCAL_BACKUP_DIR/db.sql"

# Redirection makes the dump's exit status invisible, so verify the content.
# An unusable backup has to fail here, not on the day it is needed.
if ! grep -q "INSERT INTO \`wp_posts\`" "$LOCAL_BACKUP_DIR/db.sql"; then
  echo "ERROR: dump contains no wp_posts rows - not a usable backup." >&2
  exit 1
fi

echo "[3/4] Backing up WordPress files from $REMOTE_WWW_DIR ..."
rsync -az --delete \
  -e "ssh -i $SSH_KEY -p $REMOTE_SSH_PORT -o LogLevel=ERROR" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_WWW_DIR/" "$LOCAL_WWW_DIR/"

echo "[4/4] Disabling maintenance mode ..."
$SSH_CMD "k3s kubectl exec deployment/wordpress -n $NAMESPACE -c wordpress-fpm -- \
  php /usr/local/lib/wp-cli/wp-cli.phar maintenance-mode deactivate \
  --path=/var/www/html --allow-root" > /dev/null
trap - EXIT

echo ""
echo "Backup complete → $LOCAL_BACKUP_DIR"
echo "  $(du -sh "$LOCAL_BACKUP_DIR" | cut -f1)  total"
