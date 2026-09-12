#!/usr/bin/env bash

# Back up a native deb/rpm Plex Media Server installation.
#
# Usage:
#   sudo ./plex-backup.sh
#
# Optional environment variables:
#   PLEX_SERVICE=plexmediaserver
#   PLEX_DATA_DIR='/var/lib/plexmediaserver/Library/Application Support/Plex Media Server'
#   BACKUP_DIR=/var/backups/plex
#   INCLUDE_CACHE=0  # Set to 1 to include Plex's rebuildable Cache directory.

set -Eeuo pipefail
umask 077

PLEX_SERVICE="${PLEX_SERVICE:-plexmediaserver}"
PLEX_DATA_DIR="${PLEX_DATA_DIR:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/plex}"
INCLUDE_CACHE="${INCLUDE_CACHE:-0}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "${EUID}" -eq 0 ]] || die 'run this script as root (for example, with sudo)'
[[ "$INCLUDE_CACHE" == 0 || "$INCLUDE_CACHE" == 1 ]] || \
    die 'INCLUDE_CACHE must be 0 or 1'

for command_name in systemctl tar realpath; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "required command not found: $command_name"
done

[[ -d "$PLEX_DATA_DIR" ]] || die "Plex data directory not found: $PLEX_DATA_DIR"
mkdir -p -- "$BACKUP_DIR"

data_dir="$(realpath -e -- "$PLEX_DATA_DIR")"
backup_dir="$(realpath -e -- "$BACKUP_DIR")"

case "$backup_dir/" in
    "$data_dir/"*) die 'BACKUP_DIR must not be inside PLEX_DATA_DIR' ;;
esac

data_parent="$(dirname -- "$data_dir")"
data_name="$(basename -- "$data_dir")"
timestamp="$(date +%Y%m%d-%H%M%S)"
final_file="$backup_dir/plex-$timestamp-$$.tar.gz"
partial_file="$final_file.partial"

was_active=0
restart_required=0

if systemctl is-active --quiet "$PLEX_SERVICE"; then
    was_active=1
fi

cleanup() {
    exit_status=$?

    if [[ "$restart_required" -eq 1 ]]; then
        systemctl start "$PLEX_SERVICE" || \
            printf 'Warning: could not restart %s\n' "$PLEX_SERVICE" >&2
    fi

    if [[ "$exit_status" -ne 0 && -f "$partial_file" ]]; then
        rm -f -- "$partial_file"
    fi

    exit "$exit_status"
}

trap cleanup EXIT

if [[ "$was_active" -eq 1 ]]; then
    restart_required=1
    printf 'Stopping %s...\n' "$PLEX_SERVICE"
    systemctl stop "$PLEX_SERVICE"
fi

tar_options=(-czpf "$partial_file" -C "$data_parent")
if [[ "$INCLUDE_CACHE" -eq 0 ]]; then
    tar_options+=(--exclude="$data_name/Cache")
fi

printf 'Creating backup...\n'
tar "${tar_options[@]}" "$data_name"

if [[ "$was_active" -eq 1 ]]; then
    printf 'Starting %s...\n' "$PLEX_SERVICE"
    systemctl start "$PLEX_SERVICE"
    restart_required=0
fi

printf 'Verifying backup...\n'
tar -tzf "$partial_file" >/dev/null
mv -- "$partial_file" "$final_file"

trap - EXIT
printf 'Backup complete: %s\n' "$final_file"
