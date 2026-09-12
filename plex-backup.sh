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
#   RCLONE_DEST=NAtomJZXTR:  # Default remote; set to an empty value to disable upload.
#   RCLONE_CONFIG=    # Optional path to rclone.conf.
#   LOCK_FILE=/run/plex-maintenance.lock

set -Eeuo pipefail
umask 077

PLEX_SERVICE="${PLEX_SERVICE:-plexmediaserver}"
PLEX_DATA_DIR="${PLEX_DATA_DIR:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/plex}"
INCLUDE_CACHE="${INCLUDE_CACHE:-0}"
RCLONE_DEST="${RCLONE_DEST-NAtomJZXTR:}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
LOCK_FILE="${LOCK_FILE:-/run/plex-maintenance.lock}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

remote_path_for() {
    local file_name="$1"

    if [[ "$RCLONE_DEST" == *: ]]; then
        printf '%s%s\n' "$RCLONE_DEST" "$file_name"
    else
        printf '%s/%s\n' "${RCLONE_DEST%/}" "$file_name"
    fi
}

[[ "${EUID}" -eq 0 ]] || die 'run this script as root (for example, with sudo)'
[[ "$INCLUDE_CACHE" == 0 || "$INCLUDE_CACHE" == 1 ]] || \
    die 'INCLUDE_CACHE must be 0 or 1'
[[ "$PLEX_DATA_DIR" == /* ]] || die 'PLEX_DATA_DIR must be an absolute path'
[[ "$LOCK_FILE" == /* ]] || die 'LOCK_FILE must be an absolute path'

for command_name in systemctl tar realpath sha256sum flock mkdir mv rm \
    date dirname basename; do
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
[[ "$data_dir" != / ]] || die 'PLEX_DATA_DIR must not be a filesystem root'

case "$backup_dir/" in
    "$data_dir/"*) die 'BACKUP_DIR must not be inside PLEX_DATA_DIR' ;;
esac

systemctl cat "$PLEX_SERVICE" >/dev/null 2>&1 || \
    die "systemd service not found: $PLEX_SERVICE"

lock_parent="$(dirname -- "$LOCK_FILE")"
[[ -d "$lock_parent" ]] || die "lock directory not found: $lock_parent"
[[ ! -L "$LOCK_FILE" ]] || die "lock file must not be a symbolic link: $LOCK_FILE"
exec 9>>"$LOCK_FILE"
flock -n 9 || die "another Plex maintenance operation is running (lock: $LOCK_FILE)"

data_parent="$(dirname -- "$data_dir")"
data_name="$(basename -- "$data_dir")"
timestamp="$(date +%Y%m%d-%H%M%S)"
backup_name="plex-$timestamp-$$.tar.gz"
checksum_name="$backup_name.sha256"
final_file="$backup_dir/$backup_name"
partial_file="$final_file.partial"
checksum_file="$backup_dir/$checksum_name"
partial_checksum="$checksum_file.partial"

was_active=0
restart_required=0
local_backup_complete=0

if systemctl is-active --quiet "$PLEX_SERVICE"; then
    was_active=1
fi

cleanup() {
    exit_status=$?
    trap - EXIT INT TERM HUP
    set +e

    if [[ "$restart_required" -eq 1 ]]; then
        systemctl start "$PLEX_SERVICE" || \
            printf 'Warning: could not restart %s\n' "$PLEX_SERVICE" >&2
    fi

    rm -f -- "$partial_file" "$partial_checksum"
    if [[ "$local_backup_complete" -eq 0 ]]; then
        rm -f -- "$final_file" "$checksum_file"
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

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

(
    cd -- "$backup_dir"
    sha256sum -- "$backup_name" > "$partial_checksum"
    sha256sum -c -- "$partial_checksum" >/dev/null
)
mv -- "$partial_checksum" "$checksum_file"
local_backup_complete=1

printf 'Local backup complete: %s\n' "$final_file"
printf 'Checksum complete: %s\n' "$checksum_file"

if [[ -n "$RCLONE_DEST" ]]; then
    remote_file="$(remote_path_for "$backup_name")"
    remote_checksum="$(remote_path_for "$checksum_name")"
    printf 'Uploading checksum to %s...\n' "$remote_checksum"
    rclone "${rclone_options[@]}" copyto "$checksum_file" "$remote_checksum"
    printf 'Uploading backup to %s...\n' "$remote_file"
    rclone "${rclone_options[@]}" copyto "$final_file" "$remote_file"
    printf 'Upload complete: %s\n' "$remote_file"
fi
