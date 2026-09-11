#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VW_DIR="/root/vaultwarden"
BACKUP_DIR="/root/backups/vaultwarden"
RCLONE_DEST="NAtomJZXTR:vaultwarden-backups"
LOCAL_RETENTION_DAYS=7
REMOTE_RETENTION_DAYS=90

ts="$(date +%Y%m%d-%H%M%S)"
archive="$BACKUP_DIR/vaultwarden-full-stopped-$ts.tar.gz"

mkdir -p "$BACKUP_DIR"

restart_vaultwarden() {
    docker start vaultwarden >/dev/null 2>&1 || true
}
trap restart_vaultwarden EXIT

docker stop vaultwarden

tar -C /root -czf "$archive" vaultwarden
sha256sum "$archive" > "$archive.sha256"

docker start vaultwarden
trap - EXIT

rclone copy "$archive" "$RCLONE_DEST/"
rclone copy "$archive.sha256" "$RCLONE_DEST/"

find "$BACKUP_DIR" -maxdepth 1 -type f -name 'vaultwarden-full-stopped-*.tar.gz*' -mtime +"$LOCAL_RETENTION_DAYS" -delete
rclone delete "$RCLONE_DEST" --min-age "${REMOTE_RETENTION_DAYS}d" --include 'vaultwarden-full-stopped-*.tar.gz*' --exclude '*'

echo "OK: $archive uploaded to $RCLONE_DEST"
