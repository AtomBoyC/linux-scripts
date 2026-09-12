#!/usr/bin/env bash

# Restore an archive created by plex-backup.sh without starting Plex.
#
# Usage:
#   sudo ./plex-restore.sh /path/to/plex-YYYYMMDD-HHMMSS-PID.tar.gz
#
# Optional environment variables:
#   PLEX_SERVICE=plexmediaserver
#   PLEX_DATA_DIR='/var/lib/plexmediaserver/Library/Application Support/Plex Media Server'
#   PLEX_USER=plex
#   PLEX_GROUP=plex
#   LOCK_FILE=/run/plex-maintenance.lock

set -Eeuo pipefail
umask 077

PLEX_SERVICE="${PLEX_SERVICE:-plexmediaserver}"
PLEX_DATA_DIR="${PLEX_DATA_DIR:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server}"
PLEX_USER="${PLEX_USER:-plex}"
PLEX_GROUP="${PLEX_GROUP:-plex}"
LOCK_FILE="${LOCK_FILE:-/run/plex-maintenance.lock}"

usage() {
    printf 'Usage: sudo %s /path/to/plex-backup.tar.gz\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || usage
[[ "${EUID}" -eq 0 ]] || die 'run this script as root (for example, with sudo)'
[[ "$PLEX_DATA_DIR" == /* && "${PLEX_DATA_DIR%/}" != '' ]] || \
    die 'PLEX_DATA_DIR must be an absolute path other than /'
[[ "$LOCK_FILE" == /* ]] || die 'LOCK_FILE must be an absolute path'

for command_name in systemctl tar gzip sha256sum realpath mktemp awk grep \
    id getent chown mv rm mkdir chmod cp date dirname basename flock; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "required command not found: $command_name"
done

archive_input="$1"
[[ -f "$archive_input" ]] || die "backup archive not found: $archive_input"
[[ -r "$archive_input" ]] || die "backup archive is not readable: $archive_input"
archive_source="$(realpath -e -- "$archive_input")"

plex_data_input="${PLEX_DATA_DIR%/}"
data_parent_input="$(dirname -- "$plex_data_input")"
data_name="$(basename -- "$plex_data_input")"
[[ "$data_name" != / && "$data_name" != . && "$data_name" != .. ]] || \
    die 'PLEX_DATA_DIR must identify a data directory, not a filesystem root'
[[ -d "$data_parent_input" ]] || \
    die "Plex data parent not found; install Plex before restoring: $data_parent_input"
data_parent="$(realpath -e -- "$data_parent_input")"
data_dir="$data_parent/$data_name"

[[ ! -L "$data_dir" ]] || die "PLEX_DATA_DIR must not be a symbolic link: $data_dir"
[[ ! -e "$data_dir" || -d "$data_dir" ]] || \
    die "PLEX_DATA_DIR exists but is not a directory: $data_dir"
case "$archive_source" in
    "$data_dir"|"$data_dir"/*)
        die 'the backup archive must be stored outside PLEX_DATA_DIR'
        ;;
esac

systemctl cat "$PLEX_SERVICE" >/dev/null 2>&1 || \
    die "systemd service not found: $PLEX_SERVICE"
id "$PLEX_USER" >/dev/null 2>&1 || die "Plex user not found: $PLEX_USER"
getent group "$PLEX_GROUP" >/dev/null 2>&1 || die "Plex group not found: $PLEX_GROUP"

lock_parent="$(dirname -- "$LOCK_FILE")"
[[ -d "$lock_parent" ]] || die "lock directory not found: $lock_parent"
[[ ! -L "$LOCK_FILE" ]] || die "lock file must not be a symbolic link: $LOCK_FILE"
exec 9>>"$LOCK_FILE"
flock -n 9 || die "another Plex maintenance operation is running (lock: $LOCK_FILE)"

staging_dir=
previous_data=
current_data_move_planned=0
keep_plex_stopped=0

cleanup() {
    exit_status=$?
    trap - EXIT INT TERM HUP
    set +e

    if [[ "$keep_plex_stopped" -eq 1 ]] && systemctl is-active --quiet "$PLEX_SERVICE"; then
        if ! systemctl stop "$PLEX_SERVICE"; then
            printf 'Error: could not keep %s stopped after failure\n' \
                "$PLEX_SERVICE" >&2
            exit_status=1
        fi
    fi

    if [[ "$exit_status" -ne 0 && "$current_data_move_planned" -eq 1 && \
          ! -e "$data_dir" && ! -L "$data_dir" && -n "$previous_data" && \
          -d "$previous_data" ]]; then
        printf 'Restoring the previous Plex data after failure...\n' >&2
        if ! mv -T -- "$previous_data" "$data_dir"; then
            printf 'Error: automatic rollback failed; previous data remains at %s\n' \
                "$previous_data" >&2
            exit_status=1
        fi
    fi

    if [[ -n "$staging_dir" ]]; then
        case "$staging_dir" in
            "$data_parent/.plex-restore."*)
                if ! rm -rf -- "$staging_dir"; then
                    printf 'Warning: could not remove staging directory: %s\n' \
                        "$staging_dir" >&2
                fi
                ;;
            *)
                printf 'Warning: refused to remove unexpected staging path: %s\n' \
                    "$staging_dir" >&2
                ;;
        esac
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

keep_plex_stopped=1
printf 'Stopping %s...\n' "$PLEX_SERVICE"
systemctl stop "$PLEX_SERVICE"
if systemctl is-active --quiet "$PLEX_SERVICE"; then
    die "could not stop service: $PLEX_SERVICE"
fi

# Work from a root-private copy so the input cannot be replaced between
# validation and extraction. Keeping it beside the Plex data also makes the
# final directory move atomic.
staging_dir="$(mktemp -d "$data_parent/.plex-restore.XXXXXX")"
extract_dir="$staging_dir/extracted"
manifest="$staging_dir/archive.manifest"
working_archive="$staging_dir/backup.tar.gz"
mkdir -- "$extract_dir"
printf 'Copying archive into the restore staging area...\n'
cp --reflink=auto -- "$archive_source" "$working_archive"
chmod 600 -- "$working_archive"

checksum_file="${archive_source}.sha256"
if [[ -f "$checksum_file" ]]; then
    printf 'Verifying SHA256 checksum...\n'
    expected_hash="$(awk 'NR == 1 { print $1; exit }' "$checksum_file")"
    [[ "$expected_hash" =~ ^[[:xdigit:]]{64}$ ]] || \
        die "invalid checksum file: $checksum_file"
    actual_hash="$(sha256sum -- "$working_archive")"
    actual_hash="${actual_hash%% *}"
    [[ "${actual_hash,,}" == "${expected_hash,,}" ]] || die 'SHA256 checksum mismatch'
else
    printf 'Notice: no .sha256 sidecar found; validating the gzip/tar archive instead.\n' >&2
fi

printf 'Checking gzip stream...\n'
gzip -t -- "$working_archive"

printf 'Checking archive layout...\n'
tar -tzf "$working_archive" > "$manifest"

if ! awk -v root="$data_name" '
    {
        if ($0 != root && index($0, root "/") != 1) {
            invalid = 1
        }

        component_count = split($0, component, "/")
        for (i = 1; i <= component_count; i++) {
            if (component[i] == "." || component[i] == "..") {
                invalid = 1
            }
        }
    }
    END { exit invalid }
' "$manifest"; then
    die "archive contains a path outside $data_name/"
fi

preferences_path="$data_name/Preferences.xml"
database_path="$data_name/Plug-in Support/Databases/com.plexapp.plugins.library.db"
blobs_path="$data_name/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db"

grep -Fqx "$preferences_path" "$manifest" || \
    die 'archive does not contain Preferences.xml'
grep -Fqx "$database_path" "$manifest" || \
    die 'archive does not contain the main Plex database'
grep -Fqx "$blobs_path" "$manifest" || \
    die 'archive does not contain the Plex blobs database'

printf 'Extracting into the staging directory...\n'
tar -xzpf "$working_archive" --no-same-owner --no-overwrite-dir -C "$extract_dir"
staged_data="$extract_dir/$data_name"

[[ -d "$staged_data" && ! -L "$staged_data" ]] || \
    die 'restored Plex data directory is missing or invalid'
[[ -f "$extract_dir/$preferences_path" && ! -L "$extract_dir/$preferences_path" ]] || \
    die 'restored Preferences.xml is missing or invalid'
[[ -f "$extract_dir/$database_path" && ! -L "$extract_dir/$database_path" ]] || \
    die 'restored main Plex database is missing or invalid'
[[ -f "$extract_dir/$blobs_path" && ! -L "$extract_dir/$blobs_path" ]] || \
    die 'restored Plex blobs database is missing or invalid'

printf 'Setting ownership to %s:%s...\n' "$PLEX_USER" "$PLEX_GROUP"
chown -hR -- "$PLEX_USER:$PLEX_GROUP" "$staged_data"

if [[ -L "$data_dir" ]]; then
    die "PLEX_DATA_DIR became a symbolic link during restore: $data_dir"
fi
if [[ -e "$data_dir" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    previous_data="${data_dir}.before-restore-$timestamp-$$"
    [[ ! -e "$previous_data" && ! -L "$previous_data" ]] || \
        die "safety copy already exists: $previous_data"
    printf 'Preserving current Plex data at %s...\n' "$previous_data"
    current_data_move_planned=1
    mv -T -- "$data_dir" "$previous_data"
fi

[[ ! -e "$data_dir" && ! -L "$data_dir" ]] || \
    die "PLEX_DATA_DIR reappeared during restore: $data_dir"
printf 'Installing restored Plex data...\n'
mv -T -- "$staged_data" "$data_dir"

if command -v restorecon >/dev/null 2>&1; then
    if ! restorecon -RF "$data_dir"; then
        printf 'Warning: could not restore SELinux contexts for %s\n' "$data_dir" >&2
    fi
fi

if systemctl is-active --quiet "$PLEX_SERVICE"; then
    systemctl stop "$PLEX_SERVICE"
    die 'Plex unexpectedly became active during the restore'
fi

if ! rm -rf -- "$staging_dir"; then
    printf 'Warning: could not remove staging directory: %s\n' "$staging_dir" >&2
fi
staging_dir=
trap - EXIT INT TERM HUP

printf 'Restore complete: %s\n' "$data_dir"
if [[ -n "$previous_data" ]]; then
    printf 'Previous Plex data preserved at: %s\n' "$previous_data"
fi
printf 'Plex remains stopped.\n'
