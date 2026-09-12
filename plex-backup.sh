#!/usr/bin/env bash

# Back up a native deb/rpm Plex Media Server installation.
#
# Usage:
#   sudo bash ./plex-backup.sh
#
# Optional environment variables:
#   PLEX_SERVICE=plexmediaserver
#   PLEX_DATA_DIR='/var/lib/plexmediaserver/Library/Application Support/Plex Media Server'
#   BACKUP_DIR=/var/backups/plex
#   INCLUDE_CACHE=0  # Set to 1 to include Plex's rebuildable Cache directory.
#   RCLONE_DEST=      # Example: NAtomJZXTR:plex-backups; empty disables upload.
#   RCLONE_CONFIG=    # Optional path to rclone.conf.

set -Eeuo pipefail
umask 077

PLEX_SERVICE="${PLEX_SERVICE:-plexmediaserver}"
PLEX_DATA_DIR="${PLEX_DATA_DIR:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/plex}"
INCLUDE_CACHE="${INCLUDE_CACHE:-0}"
RCLONE_DEST="${RCLONE_DEST:-}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"

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

rclone_options=()
if [[ -n "$RCLONE_DEST" ]]; then
    command -v rclone >/dev/null 2>&1 || die 'required command not found: rclone'

    # sudo normally changes HOME to /root. Reuse the invoking user's standard
    # rclone configuration when no explicit RCLONE_CONFIG was supplied.
    if [[ -z "$RCLONE_CONFIG" && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        command -v getent >/dev/null 2>&1 || die 'required command not found: getent'
        passwd_entry="$(getent passwd "$SUDO_USER")" || \
            die "could not resolve sudo user: $SUDO_USER"
        IFS=: read -r _ _ _ _ _ sudo_user_home _ <<< "$passwd_entry"
        candidate_config="$sudo_user_home/.config/rclone/rclone.conf"
        if [[ -f "$candidate_config" ]]; then
            RCLONE_CONFIG="$candidate_config"
        fi
    fi

    if [[ -n "$RCLONE_CONFIG" ]]; then
        [[ -r "$RCLONE_CONFIG" ]] || die "rclone config is not readable: $RCLONE_CONFIG"
        rclone_options+=(--config "$RCLONE_CONFIG")
    fi
fi

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
printf 'Local backup complete: %s\n' "$final_file"

if [[ -n "$RCLONE_DEST" ]]; then
    remote_file="${RCLONE_DEST%/}/$(basename -- "$final_file")"
    printf 'Uploading to %s...\n' "$remote_file"
    rclone "${rclone_options[@]}" copyto "$final_file" "$remote_file"
    printf 'Upload complete: %s\n' "$remote_file"
fi
