#!/usr/bin/env bash

# Back up a Docker Vaultwarden installation while the container is stopped.
#
# Usage:
#   sudo ./vaultwarden-backup.sh
#
# Optional environment variables:
#   CONTAINER_NAME=vaultwarden
#   VW_DIR=/root/vaultwarden
#   BACKUP_DIR=/root/backups/vaultwarden
#   RCLONE_DEST=NAtomJZXTR:vaultwarden-backups
#   RCLONE_CONFIG=       # Optional path to rclone.conf.
#   RCLONE_CONFIG_PASS=  # Required by rclone for an encrypted config.
#   LOCAL_RETENTION_DAYS=7
#   REMOTE_RETENTION_DAYS=90
#   BACKUP_HOST=my-server
#   LOCK_FILE=/run/vaultwarden-backup.lock
#
# This script supports Vaultwarden's SQLite backend. Every /data mount must be
# a bind mount inside VW_DIR. Keep the Compose file and .env inside VW_DIR so
# the archive also contains the information needed to rebuild the container.
# Point RCLONE_DEST at an rclone crypt remote if cloud encryption is needed.

set -Eeuo pipefail
umask 077

CONTAINER_NAME="${CONTAINER_NAME:-vaultwarden}"
VW_DIR="${VW_DIR:-/root/vaultwarden}"
BACKUP_DIR="${BACKUP_DIR:-/root/backups/vaultwarden}"
RCLONE_DEST="${RCLONE_DEST-NAtomJZXTR:vaultwarden-backups}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-7}"
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-90}"
BACKUP_HOST="${BACKUP_HOST:-}"
LOCK_FILE="${LOCK_FILE:-/run/vaultwarden-backup.lock}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "${EUID}" -eq 0 ]] || die 'run this script as root (for example, with sudo)'
[[ "$LOCAL_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || \
    die 'LOCAL_RETENTION_DAYS must be a positive integer'
[[ "$REMOTE_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || \
    die 'REMOTE_RETENTION_DAYS must be a positive integer'

for command_name in docker tar sha256sum realpath flock find hostname tr grep \
    date dirname basename mkdir mv rm; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "required command not found: $command_name"
done

if [[ -z "$BACKUP_HOST" ]]; then
    BACKUP_HOST="$(hostname -s)"
fi

rclone_options=(--ask-password=false)
if [[ -n "$RCLONE_DEST" ]]; then
    command -v rclone >/dev/null 2>&1 || die 'required command not found: rclone'

    if [[ -n "$RCLONE_CONFIG" ]]; then
        [[ -r "$RCLONE_CONFIG" ]] || die "rclone config is not readable: $RCLONE_CONFIG"
        rclone_options+=(--config "$RCLONE_CONFIG")
    fi
fi

[[ -d "$VW_DIR" ]] || die "Vaultwarden directory not found: $VW_DIR"
mkdir -p -- "$BACKUP_DIR"

vw_dir="$(realpath -e -- "$VW_DIR")"
backup_dir="$(realpath -e -- "$BACKUP_DIR")"

case "$backup_dir/" in
    "$vw_dir/"*) die 'BACKUP_DIR must not be inside VW_DIR' ;;
esac

lock_parent="$(dirname -- "$LOCK_FILE")"
[[ -d "$lock_parent" ]] || die "lock directory not found: $lock_parent"
[[ ! -L "$LOCK_FILE" ]] || die "lock file must not be a symbolic link: $LOCK_FILE"
exec 9>>"$LOCK_FILE"
flock -n 9 || die "another backup is already running (lock: $LOCK_FILE)"

docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || \
    die "Docker container not found: $CONTAINER_NAME"

container_env="$(
    docker inspect --format \
        '{{range .Config.Env}}{{println .}}{{end}}' \
        "$CONTAINER_NAME"
)"

data_folder=/data
database_url=
while IFS= read -r env_entry; do
    case "$env_entry" in
        DATA_FOLDER=*) data_folder="${env_entry#DATA_FOLDER=}" ;;
        DATABASE_URL=*) database_url="${env_entry#DATABASE_URL=}" ;;
    esac
done <<< "$container_env"

[[ "${data_folder%/}" == /data ]] || \
    die "unsupported DATA_FOLDER for container $CONTAINER_NAME: $data_folder"

case "$database_url" in
    ''|/data/*|data/*|sqlite:*|file:*) ;;
    mysql:*|postgres:*|postgresql:*)
        die 'container uses an external database; create a database dump before backing up'
        ;;
    *) die 'unsupported DATABASE_URL; this script only backs up SQLite in /data' ;;
esac

all_mounts="$(
    docker inspect --format \
        '{{range .Mounts}}{{printf "%s\t%s\t%s\n" .Destination .Type .Source}}{{end}}' \
        "$CONTAINER_NAME"
)"

data_dir=
while IFS=$'\t' read -r mount_destination mount_type mount_source; do
    case "$mount_destination" in
        /data|/data/*)
            [[ "$mount_type" == bind ]] || \
                die "$mount_destination uses a $mount_type mount; every /data mount must be a bind mount inside VW_DIR"
            [[ -d "$mount_source" ]] || \
                die "mount source directory not found for $mount_destination: $mount_source"

            mount_source="$(realpath -e -- "$mount_source")"
            case "$mount_source" in
                "$vw_dir"|"$vw_dir"/*) ;;
                *) die "mount source for $mount_destination must be inside VW_DIR: $mount_source" ;;
            esac

            if [[ "$mount_destination" == /data ]]; then
                data_dir="$mount_source"
            fi
            ;;
    esac
done <<< "$all_mounts"

[[ -n "$data_dir" ]] || die "container $CONTAINER_NAME has no /data bind mount"
[[ -f "$data_dir/db.sqlite3" ]] || \
    die "SQLite database not found at $data_dir/db.sqlite3; external databases need a separate dump"
if [[ -f "$data_dir/config.json" ]] && \
    grep -Eiq '"database_url"[[:space:]]*:[[:space:]]*"(mysql|postgres|postgresql):' \
        "$data_dir/config.json"; then
    die 'config.json selects an external database; create a database dump before backing up'
fi

if [[ -n "$RCLONE_DEST" ]]; then
    # Check credentials and create the destination before stopping Vaultwarden.
    rclone "${rclone_options[@]}" mkdir "$RCLONE_DEST"
fi

vw_parent="$(dirname -- "$vw_dir")"
vw_name="$(basename -- "$vw_dir")"
timestamp="$(date +%Y%m%d-%H%M%S)"
safe_host="$(printf '%s' "$BACKUP_HOST" | tr -c 'A-Za-z0-9._-' '-')"
safe_host="${safe_host:0:63}"
[[ "$safe_host" =~ [A-Za-z0-9] ]] || die 'BACKUP_HOST must contain a letter or number'
archive_name="vaultwarden-full-stopped-$safe_host-$timestamp-$$-$RANDOM.tar.gz"
checksum_name="$archive_name.sha256"
archive="$backup_dir/$archive_name"
checksum="$backup_dir/$checksum_name"
partial_archive="$archive.partial"
partial_checksum="$checksum.partial"

[[ ! -e "$archive" && ! -e "$checksum" ]] || \
    die "backup filename already exists: $archive_name"

was_running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")"
restart_required=0
local_backup_complete=0
local_retention_complete=0
local_retention_minutes=$((LOCAL_RETENTION_DAYS * 1440))

prune_local_backups() {
    find "$backup_dir" -maxdepth 1 -type f \
        \( -name 'vaultwarden-full-stopped-*.tar.gz' \
           -o -name 'vaultwarden-full-stopped-*.tar.gz.sha256' \) \
        -mmin "+$local_retention_minutes" -delete
}

cleanup() {
    exit_status=$?
    trap - EXIT INT TERM HUP
    set +e

    if [[ "$restart_required" -eq 1 ]]; then
        printf 'Restoring container state for %s...\n' "$CONTAINER_NAME" >&2
        if ! docker start "$CONTAINER_NAME" >/dev/null; then
            printf 'Error: could not restart container %s\n' "$CONTAINER_NAME" >&2
            exit_status=1
        fi
    fi

    rm -f -- "$partial_archive" "$partial_checksum"
    if [[ "$local_backup_complete" -eq 0 ]]; then
        rm -f -- "$archive" "$checksum"
    elif [[ "$local_retention_complete" -eq 0 ]]; then
        printf 'Deleting local backups older than %s days...\n' "$LOCAL_RETENTION_DAYS"
        if ! prune_local_backups; then
            printf 'Error: could not enforce local backup retention\n' >&2
            exit_status=1
        fi
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ "$was_running" == true ]]; then
    restart_required=1
    printf 'Stopping %s...\n' "$CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" >/dev/null
elif [[ "$was_running" != false ]]; then
    die "could not determine whether container is running: $CONTAINER_NAME"
fi

if command -v sqlite3 >/dev/null 2>&1; then
    printf 'Checking SQLite database...\n'
    database_check="$(sqlite3 -readonly "$data_dir/db.sqlite3" 'PRAGMA quick_check;')" || \
        die 'SQLite quick_check could not be completed'
    [[ "$database_check" == ok ]] || die 'SQLite quick_check reported corruption'
else
    printf 'Warning: sqlite3 not found; skipping database integrity check\n' >&2
fi

printf 'Creating backup...\n'
tar -C "$vw_parent" -czf "$partial_archive" -- "$vw_name"

if [[ "$was_running" == true ]]; then
    printf 'Starting %s...\n' "$CONTAINER_NAME"
    docker start "$CONTAINER_NAME" >/dev/null
    [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" == true ]] || \
        die "container did not stay running after restart: $CONTAINER_NAME"
    restart_required=0
fi

printf 'Verifying backup...\n'
tar -tzf "$partial_archive" >/dev/null
mv -- "$partial_archive" "$archive"
(
    cd -- "$backup_dir"
    sha256sum -- "$archive_name" > "$partial_checksum"
)
mv -- "$partial_checksum" "$checksum"
(
    cd -- "$backup_dir"
    sha256sum -c -- "$checksum_name" >/dev/null
)
local_backup_complete=1
printf 'Local backup complete: %s\n' "$archive"

remote_path() {
    if [[ "$RCLONE_DEST" == *: ]]; then
        printf '%s%s' "$RCLONE_DEST" "$1"
    else
        printf '%s/%s' "${RCLONE_DEST%/}" "$1"
    fi
}

if [[ -n "$RCLONE_DEST" ]]; then
    remote_checksum="$(remote_path "$checksum_name")"
    remote_archive="$(remote_path "$archive_name")"

    # Upload the checksum first so a visible archive always has its checksum.
    printf 'Uploading checksum to %s...\n' "$remote_checksum"
    rclone "${rclone_options[@]}" copyto "$checksum" "$remote_checksum" --immutable
    printf 'Uploading backup to %s...\n' "$remote_archive"
    rclone "${rclone_options[@]}" copyto "$archive" "$remote_archive" --immutable

    printf 'Deleting remote backups older than %s days...\n' "$REMOTE_RETENTION_DAYS"
    rclone "${rclone_options[@]}" delete "$RCLONE_DEST" \
        --min-age "${REMOTE_RETENTION_DAYS}d" \
        --filter '+ /vaultwarden-full-stopped-*.tar.gz' \
        --filter '+ /vaultwarden-full-stopped-*.tar.gz.sha256' \
        --filter '- **'
fi

printf 'Deleting local backups older than %s days...\n' "$LOCAL_RETENTION_DAYS"
prune_local_backups
local_retention_complete=1

trap - EXIT INT TERM HUP
if [[ -n "$RCLONE_DEST" ]]; then
    printf 'OK: %s uploaded to %s\n' "$archive" "$RCLONE_DEST"
else
    printf 'OK: %s\n' "$archive"
fi
