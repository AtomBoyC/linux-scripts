#!/usr/bin/env bash

# Restore a full archive created by vaultwarden-backup.sh.
#
# Usage:
#   sudo ./vaultwarden-restore.sh /path/to/vaultwarden-full-stopped-*.tar.gz
#
# Optional environment variables:
#   CONTAINER_NAME=vaultwarden
#   VW_DIR=/root/vaultwarden
#   COMPOSE_SERVICE=       # Detected from the current container or restored Compose file.
#   COMPOSE_FILE_NAME=     # A Compose filename inside VW_DIR; normally detected automatically.
#   START_CONTAINER=1      # Set to 0 to create the restored container but leave it stopped.
#   STARTUP_TIMEOUT=120
#   DATA_DIR_REL=          # Directory inside VW_DIR mounted at /data; normally detected automatically.
#   SKIP_SQLITE_CHECK=0
#   ALLOW_MISSING_CHECKSUM=0
#   LOCK_FILE=/run/vaultwarden-backup.lock

set -Eeuo pipefail
umask 077

CONTAINER_NAME="${CONTAINER_NAME:-vaultwarden}"
VW_DIR="${VW_DIR:-/root/vaultwarden}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-}"
COMPOSE_FILE_NAME="${COMPOSE_FILE_NAME:-}"
START_CONTAINER="${START_CONTAINER:-1}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-120}"
DATA_DIR_REL="${DATA_DIR_REL:-}"
SKIP_SQLITE_CHECK="${SKIP_SQLITE_CHECK:-0}"
ALLOW_MISSING_CHECKSUM="${ALLOW_MISSING_CHECKSUM:-0}"
LOCK_FILE="${LOCK_FILE:-/run/vaultwarden-backup.lock}"

usage() {
    printf 'Usage: sudo %s /path/to/vaultwarden-backup.tar.gz\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || usage
[[ "${EUID}" -eq 0 ]] || die 'run this script as root (for example, with sudo)'
[[ "$VW_DIR" == /* && "${VW_DIR%/}" != '' ]] || \
    die 'VW_DIR must be an absolute path other than /'
[[ "$LOCK_FILE" == /* ]] || die 'LOCK_FILE must be an absolute path'
[[ "$START_CONTAINER" == 0 || "$START_CONTAINER" == 1 ]] || \
    die 'START_CONTAINER must be 0 or 1'
[[ "$SKIP_SQLITE_CHECK" == 0 || "$SKIP_SQLITE_CHECK" == 1 ]] || \
    die 'SKIP_SQLITE_CHECK must be 0 or 1'
[[ "$ALLOW_MISSING_CHECKSUM" == 0 || "$ALLOW_MISSING_CHECKSUM" == 1 ]] || \
    die 'ALLOW_MISSING_CHECKSUM must be 0 or 1'
[[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || \
    die 'STARTUP_TIMEOUT must be a positive integer'

for command_name in docker tar gzip sha256sum realpath mktemp python3 awk \
    find grep cp chmod mv rm mkdir date dirname basename flock sleep; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "required command not found: $command_name"
done

docker info >/dev/null 2>&1 || die 'Docker daemon is not available'

compose_command=()
if docker compose version >/dev/null 2>&1; then
    compose_command=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    compose_command=(docker-compose)
else
    die 'Docker Compose is required (docker compose or docker-compose)'
fi

discover_target_containers() {
    local target_dir="$1"
    local container_ids_text
    local container_id
    local container_ids=()

    if ! container_ids_text="$(docker ps -a -q)"; then
        return 1
    fi
    while IFS= read -r container_id; do
        [[ -n "$container_id" ]] && container_ids+=("$container_id")
    done <<< "$container_ids_text"
    [[ "${#container_ids[@]}" -gt 0 ]] || return 0

    docker inspect "${container_ids[@]}" | python3 -c '
import json
import os
import sys

target = os.path.realpath(sys.argv[1])
separator = "\x1f"

try:
    for document in json.load(sys.stdin):
        uses_target = False
        for mount in document.get("Mounts", []):
            if (mount.get("Destination") != "/data" or
                    mount.get("Type") != "bind" or
                    not mount.get("Source")):
                continue
            source = os.path.realpath(mount["Source"])
            try:
                uses_target = os.path.commonpath((target, source)) == target
            except ValueError:
                uses_target = False
            if uses_target:
                break

        if not uses_target:
            continue

        labels = document.get("Config", {}).get("Labels") or {}
        values = [
            document.get("Id", ""),
            document.get("Name", "").lstrip("/"),
            "true" if document.get("State", {}).get("Running") else "false",
            labels.get("com.docker.compose.project", ""),
            labels.get("com.docker.compose.service", ""),
        ]
        if not values[0] or not values[1]:
            raise ValueError("container identity is incomplete")
        if any(separator in value or "\n" in value or "\r" in value
               for value in values):
            raise ValueError("container metadata contains a control character")
        print(separator.join(values))
except (AttributeError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"Error: could not inspect containers using VW_DIR: {error}", file=sys.stderr)
    raise SystemExit(1)
' "$target_dir"
}

archive_input="$1"
[[ -f "$archive_input" && ! -L "$archive_input" ]] || \
    die "backup archive must be a regular, non-symbolic-link file: $archive_input"
[[ -r "$archive_input" ]] || die "backup archive is not readable: $archive_input"
archive_source="$(realpath -e -- "$archive_input")"

vw_input="${VW_DIR%/}"
vw_parent_input="$(dirname -- "$vw_input")"
vw_name="$(basename -- "$vw_input")"
[[ "$vw_name" != / && "$vw_name" != . && "$vw_name" != .. ]] || \
    die 'VW_DIR must identify a directory, not a filesystem root'
[[ -d "$vw_parent_input" ]] || \
    die "Vaultwarden parent directory not found: $vw_parent_input"
vw_parent="$(realpath -e -- "$vw_parent_input")"
vw_dir="$vw_parent/$vw_name"

[[ ! -L "$vw_dir" ]] || die "VW_DIR must not be a symbolic link: $vw_dir"
[[ ! -e "$vw_dir" || -d "$vw_dir" ]] || \
    die "VW_DIR exists but is not a directory: $vw_dir"
case "$archive_source" in
    "$vw_dir"|"$vw_dir"/*) die 'the backup archive must be stored outside VW_DIR' ;;
esac

if [[ -n "$COMPOSE_FILE_NAME" ]]; then
    case "$COMPOSE_FILE_NAME" in
        */*|.|..) die 'COMPOSE_FILE_NAME must be a filename inside VW_DIR' ;;
    esac
fi
if [[ -n "$DATA_DIR_REL" ]]; then
    [[ "$DATA_DIR_REL" != /* ]] || die 'DATA_DIR_REL must be relative to VW_DIR'
    if [[ "$DATA_DIR_REL" != . ]]; then
        case "/$DATA_DIR_REL/" in
            */../*|*/./*) die 'DATA_DIR_REL must not contain . or .. path components' ;;
        esac
    fi
fi

lock_parent="$(dirname -- "$LOCK_FILE")"
[[ -d "$lock_parent" ]] || die "lock directory not found: $lock_parent"
[[ ! -L "$LOCK_FILE" ]] || die "lock file must not be a symbolic link: $LOCK_FILE"
exec 9>>"$LOCK_FILE"
flock -n 9 || \
    die "another Vaultwarden maintenance operation is running (lock: $LOCK_FILE)"

old_container_exists=0
old_container_was_running=0
old_container_id=
old_container_name=
old_compose_project=
old_compose_service=

if ! target_container_records_text="$(discover_target_containers "$vw_dir")"; then
    die "could not inspect containers using VW_DIR: $vw_dir"
fi
target_container_records=()
while IFS= read -r container_record; do
    [[ -n "$container_record" ]] && target_container_records+=("$container_record")
done <<< "$target_container_records_text"
[[ "${#target_container_records[@]}" -le 1 ]] || \
    die "multiple containers use /data from VW_DIR; stop and resolve them manually: $vw_dir"

exact_container_id=
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    exact_container_id="$(docker inspect --format '{{.Id}}' "$CONTAINER_NAME")"
    [[ -n "$exact_container_id" ]] || \
        die "could not identify existing container: $CONTAINER_NAME"
    [[ "${#target_container_records[@]}" -eq 1 ]] || \
        die "container $CONTAINER_NAME does not use a /data bind mount inside VW_DIR"
fi

if [[ "${#target_container_records[@]}" -eq 1 ]]; then
    IFS=$'\x1f' read -r old_container_id old_container_name old_running_state \
        old_compose_project old_compose_service <<< "${target_container_records[0]}"
    if [[ -n "$exact_container_id" && "$exact_container_id" != "$old_container_id" ]]; then
        die "container $CONTAINER_NAME conflicts with the container using VW_DIR: $old_container_name"
    fi
    old_container_exists=1
    case "$old_running_state" in
        true) old_container_was_running=1 ;;
        false) ;;
        *) die "could not determine container state: $old_container_name" ;;
    esac
    if [[ -z "$exact_container_id" ]]; then
        printf 'Notice: detected current Vaultwarden container by its /data mount: %s\n' \
            "$old_container_name"
    fi
fi

if [[ -n "$old_compose_project" && -z "$old_compose_service" ]] || \
   [[ -z "$old_compose_project" && -n "$old_compose_service" ]]; then
    die "existing container has incomplete Docker Compose labels: $old_container_name"
fi

if [[ -z "$COMPOSE_SERVICE" && -n "$old_compose_service" ]]; then
    COMPOSE_SERVICE="$old_compose_service"
elif [[ -n "$old_compose_service" && "$COMPOSE_SERVICE" != "$old_compose_service" ]]; then
    die "COMPOSE_SERVICE does not match the existing container service: $old_compose_service"
fi

compose_project_options=()
if [[ -n "$old_compose_project" ]]; then
    compose_project_options=(-p "$old_compose_project")
fi

staging_dir=
previous_vw=
failed_vw=
compose_file_name=
old_compose_file_name=
current_move_planned=0
new_install_attempted=0
compose_operation_started=0
keep_container_stopped=0
old_container_renamed=0
old_container_backup_name=
restored_container_id=

run_compose_file() {
    local project_dir="$1"
    local file_name="$2"
    shift 2

    (
        cd -- "$project_dir"
        unset COMPOSE_FILE COMPOSE_PROJECT_NAME
        "${compose_command[@]}" "${compose_project_options[@]}" \
            -f "$file_name" "$@"
    )
}

run_compose() {
    local project_dir="$1"
    shift
    run_compose_file "$project_dir" "$compose_file_name" "$@"
}

collect_compose_files() {
    local search_dir="$1"
    local candidate
    compose_matches=()

    for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [[ -L "$search_dir/$candidate" ]]; then
            die "Compose file must not be a symbolic link: $search_dir/$candidate"
        fi
        if [[ -f "$search_dir/$candidate" ]]; then
            compose_matches+=("$candidate")
        fi
    done
}

reject_compose_overrides() {
    local search_dir="$1"
    local override_name

    for override_name in compose.override.yaml compose.override.yml \
        docker-compose.override.yaml docker-compose.override.yml; do
        if [[ -e "$search_dir/$override_name" || -L "$search_dir/$override_name" ]]; then
            die "Compose override files are not supported automatically; merge it into the main file before restoring: $search_dir/$override_name"
        fi
    done
}

inspect_data_mounts() {
    local container_id="$1"
    local target_dir="$2"

    docker inspect "$container_id" | python3 -c '
import json
import os
import sys

target = os.path.realpath(sys.argv[1])

try:
    documents = json.load(sys.stdin)
    if len(documents) != 1:
        raise ValueError("docker inspect did not return exactly one container")

    mounts = []
    data_mount_found = False
    for mount in documents[0].get("Mounts", []):
        destination = mount.get("Destination", "")
        if destination != "/data" and not destination.startswith("/data/"):
            continue

        if mount.get("Type") != "bind" or not mount.get("Source"):
            raise ValueError(f"{destination} must be a bind mount")

        source = os.path.realpath(mount["Source"])
        try:
            inside_target = os.path.commonpath((target, source)) == target
        except ValueError:
            inside_target = False
        if not inside_target:
            raise ValueError(f"{destination} mount source is outside VW_DIR")
        if any(character in source for character in "\t\r\n"):
            raise ValueError("mount source contains a tab or newline")

        mounts.append((destination.rstrip("/") or "/", source))
        if destination == "/data":
            data_mount_found = True

    if not data_mount_found:
        raise ValueError("the restored container has no /data bind mount")

    def host_path(container_path):
        candidates = []
        for destination, source in mounts:
            if container_path == destination:
                candidates.append((len(destination), source))
            elif container_path.startswith(destination + "/"):
                suffix = container_path[len(destination) + 1:]
                candidates.append((len(destination), os.path.join(source, suffix)))
        if not candidates:
            raise ValueError(f"no bind mount covers {container_path}")
        return os.path.realpath(max(candidates, key=lambda item: item[0])[1])

    database_path = host_path("/data/db.sqlite3")
    config_path = host_path("/data/config.json")
    if any(character in database_path + config_path for character in "\t\r\n"):
        raise ValueError("resolved data path contains a tab or newline")
    print(f"{database_path}\t{config_path}")
except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"Error: invalid restored container mounts: {error}", file=sys.stderr)
    raise SystemExit(1)
' "$target_dir"
}

inspect_vaultwarden_environment() {
    local container_id="$1"

    docker inspect "$container_id" | python3 -c '
import json
import sys

keys = (
    "DATA_FOLDER",
    "DATABASE_URL",
    "CONFIG_FILE",
    "ENV_FILE",
    "DATA_FOLDER_FILE",
    "DATABASE_URL_FILE",
    "CONFIG_FILE_FILE",
    "ENV_FILE_FILE",
)
separator = "\x1f"

try:
    documents = json.load(sys.stdin)
    if len(documents) != 1:
        raise ValueError("docker inspect did not return exactly one container")
    values = {key: "" for key in keys}
    for entry in documents[0].get("Config", {}).get("Env") or []:
        name, delimiter, value = entry.partition("=")
        if delimiter and name in values:
            values[name] = value
    selected = [values[key] for key in keys]
    if any(separator in value or "\n" in value or "\r" in value
           for value in selected):
        raise ValueError("relevant environment value contains a control character")
    print(separator.join(selected))
except (AttributeError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"Error: could not inspect restored container environment: {error}", file=sys.stderr)
    raise SystemExit(1)
'
}

validate_database_url() {
    local database_url_value="$1"
    local data_folder_value="$2"
    local source_label="$3"

    [[ -n "$database_url_value" ]] || return 0

    if ! printf '%s' "$database_url_value" | \
        python3 -c '
import posixpath
import sys

data_folder, source_label = sys.argv[1:]
value = sys.stdin.read()

if value != value.strip():
    print(f"Error: {source_label} contains leading or trailing whitespace", file=sys.stderr)
    raise SystemExit(1)

if "?" in value or "#" in value:
    print(f"Error: {source_label} must not contain query or fragment options", file=sys.stderr)
    raise SystemExit(1)

value = value.replace("%DATA_FOLDER%", data_folder)
if value.startswith("sqlite://"):
    value = value[len("sqlite://"):]
elif ":" in value:
    print(f"Error: {source_label} is not a supported SQLite path", file=sys.stderr)
    raise SystemExit(1)

while value.startswith("//"):
    value = value[1:]
if value.startswith("./"):
    value = value[2:]
if not value.startswith("/"):
    value = "/" + value

if posixpath.normpath(value) != "/data/db.sqlite3":
    print(f"Error: {source_label} does not point to /data/db.sqlite3", file=sys.stderr)
    raise SystemExit(1)
' "$data_folder_value" "$source_label"
    then
        return 1
    fi
}

validate_config_file_path() {
    local config_file_value="$1"
    local data_folder_value="$2"

    [[ -n "$config_file_value" ]] || return 0

    if ! printf '%s' "$config_file_value" | \
        python3 -c '
import posixpath
import sys

data_folder = sys.argv[1]
value = sys.stdin.read()

if value != value.strip() or "?" in value or "#" in value:
    print("Error: restored container CONFIG_FILE is not a plain path", file=sys.stderr)
    raise SystemExit(1)

value = value.replace("%DATA_FOLDER%", data_folder)
if value.startswith("./"):
    value = value[2:]
if not value.startswith("/"):
    value = "/" + value

if posixpath.normpath(value) != "/data/config.json":
    print("Error: restored container CONFIG_FILE does not point to /data/config.json", file=sys.stderr)
    raise SystemExit(1)
' "$data_folder_value"
    then
        return 1
    fi
}

cleanup() {
    exit_status=$?
    trap - EXIT INT TERM HUP
    set +e

    container_cleanup_safe=1
    if [[ "$exit_status" -ne 0 && "$compose_operation_started" -eq 1 && \
          -n "$compose_file_name" && -d "$vw_dir" ]]; then
        printf 'Stopping and removing the failed restored container...\n' >&2
        container_ids=()
        if ! docker info >/dev/null 2>&1; then
            container_cleanup_safe=0
        elif [[ -n "$restored_container_id" ]] && \
             docker inspect "$restored_container_id" >/dev/null 2>&1; then
            container_ids+=("$restored_container_id")
        elif container_ids_text="$(
            run_compose "$vw_dir" ps -a -q "$COMPOSE_SERVICE" 2>/dev/null
        )"; then
            while IFS= read -r container_id; do
                [[ -n "$container_id" ]] && container_ids+=("$container_id")
            done <<< "$container_ids_text"
        else
            container_cleanup_safe=0
        fi

        if [[ "${#container_ids[@]}" -eq 0 ]] && \
           docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
            container_ids+=("$CONTAINER_NAME")
        fi

        for container_id in "${container_ids[@]}"; do
            if ! docker rm -f "$container_id" >/dev/null 2>&1 || \
               docker inspect "$container_id" >/dev/null 2>&1; then
                container_cleanup_safe=0
            fi
        done

        if [[ "$container_cleanup_safe" -eq 0 ]]; then
            printf 'Error: could not prove the failed container is stopped; directory rollback was not attempted.\n' >&2
            exit_status=1
        fi
    elif [[ "$exit_status" -ne 0 && "$keep_container_stopped" -eq 1 && \
            -n "$old_container_id" ]] && \
         docker inspect "$old_container_id" >/dev/null 2>&1 && \
         [[ "$(docker inspect --format '{{.State.Running}}' "$old_container_id")" == true ]]; then
        if ! docker stop "$old_container_id" >/dev/null 2>&1 || \
           [[ "$(docker inspect --format '{{.State.Running}}' "$old_container_id" 2>/dev/null)" != false ]]; then
            printf 'Warning: could not stop container %s after failure\n' \
                "$old_container_name" >&2
            container_cleanup_safe=0
            exit_status=1
        fi
    fi

    rollback_complete=0
    if [[ "$exit_status" -ne 0 && "$current_move_planned" -eq 1 && \
          "$container_cleanup_safe" -eq 1 && -n "$previous_vw" && \
          -d "$previous_vw" ]]; then
        if [[ -e "$vw_dir" || -L "$vw_dir" ]]; then
            failed_vw="${vw_dir}.failed-restore-$(date +%Y%m%d-%H%M%S)-$$"
            if [[ ! -e "$failed_vw" && ! -L "$failed_vw" ]] && \
               mv -T -- "$vw_dir" "$failed_vw"; then
                printf 'Failed restored data preserved at: %s\n' "$failed_vw" >&2
            else
                printf 'Error: could not preserve the failed restored data at %s\n' \
                    "$vw_dir" >&2
                failed_vw=
            fi
        fi

        if [[ ! -e "$vw_dir" && ! -L "$vw_dir" ]]; then
            if mv -T -- "$previous_vw" "$vw_dir"; then
                rollback_complete=1
                printf 'Previous Vaultwarden data restored after failure.\n' >&2
            else
                printf 'Error: automatic directory rollback failed; previous data remains at %s\n' \
                    "$previous_vw" >&2
                exit_status=1
            fi
        fi
    fi

    if [[ "$exit_status" -ne 0 && "$old_container_renamed" -eq 1 && \
          ( "$rollback_complete" -eq 1 || "$current_move_planned" -eq 0 ) ]]; then
        if docker inspect "$old_container_backup_name" >/dev/null 2>&1 && \
           ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
            docker rename "$old_container_backup_name" "$CONTAINER_NAME" >/dev/null 2>&1 || \
                printf 'Warning: could not restore the original container name\n' >&2
        fi
    fi

    if [[ "$exit_status" -ne 0 && "$old_container_exists" -eq 1 && \
          ( "$new_install_attempted" -eq 0 || "$rollback_complete" -eq 1 || \
            "$current_move_planned" -eq 0 ) ]]; then
        if docker inspect "$old_container_id" >/dev/null 2>&1; then
            if [[ "$old_container_was_running" -eq 1 ]]; then
                docker start "$old_container_id" >/dev/null 2>&1 || \
                    printf 'Warning: could not restart the original container\n' >&2
            fi
        elif [[ "$rollback_complete" -eq 1 && -n "$old_compose_file_name" && \
                -f "$vw_dir/$old_compose_file_name" ]]; then
            if [[ "$old_container_was_running" -eq 1 ]]; then
                if ! run_compose_file "$vw_dir" "$old_compose_file_name" \
                    up -d --force-recreate --no-deps "$old_compose_service" \
                    >/dev/null 2>&1; then
                    printf 'Warning: could not recreate the original running container after rollback\n' >&2
                    exit_status=1
                fi
            elif ! run_compose_file "$vw_dir" "$old_compose_file_name" \
                up --no-start --force-recreate --no-deps "$old_compose_service" \
                >/dev/null 2>&1; then
                printf 'Warning: could not recreate the original stopped container after rollback\n' >&2
                exit_status=1
            fi
        else
            printf 'Warning: the original container could not be restored automatically\n' >&2
            exit_status=1
        fi
    fi

    if [[ -n "$staging_dir" ]]; then
        case "$staging_dir" in
            "$vw_parent/.vaultwarden-restore."*)
                rm -rf -- "$staging_dir" || \
                    printf 'Warning: could not remove staging directory: %s\n' \
                        "$staging_dir" >&2
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

staging_dir="$(mktemp -d "$vw_parent/.vaultwarden-restore.XXXXXX")"
extract_dir="$staging_dir/extracted"
working_archive="$staging_dir/backup.tar.gz"
mkdir -- "$extract_dir"

printf 'Copying archive into the restore staging area...\n'
cp --reflink=auto -- "$archive_source" "$working_archive"
chmod 600 -- "$working_archive"

checksum_source="${archive_source}.sha256"
if [[ -f "$checksum_source" && ! -L "$checksum_source" ]]; then
    printf 'Verifying SHA256 checksum...\n'
    expected_hash="$(awk 'NR == 1 { print $1; exit }' "$checksum_source")"
    [[ "$expected_hash" =~ ^[[:xdigit:]]{64}$ ]] || \
        die "invalid checksum file: $checksum_source"
    actual_hash="$(sha256sum -- "$working_archive")"
    actual_hash="${actual_hash%% *}"
    [[ "${actual_hash,,}" == "${expected_hash,,}" ]] || die 'SHA256 checksum mismatch'
elif [[ "$ALLOW_MISSING_CHECKSUM" == 1 ]]; then
    printf 'Warning: no usable .sha256 sidecar found; archive integrity was not checked.\n' >&2
else
    die "checksum file not found; set ALLOW_MISSING_CHECKSUM=1 only for a trusted legacy backup: $checksum_source"
fi

printf 'Checking gzip stream and archive members...\n'
gzip -t -- "$working_archive"
python3 - "$working_archive" "$vw_name" <<'PY'
import sys
import tarfile

archive, expected_root = sys.argv[1:]
seen = set()
member_count = 0

try:
    with tarfile.open(archive, mode="r:gz") as bundle:
        for member in bundle:
            member_count += 1
            raw_name = member.name
            if raw_name.startswith("/"):
                raise ValueError(f"absolute archive path: {raw_name!r}")

            trimmed = raw_name.rstrip("/")
            parts = trimmed.split("/") if trimmed else []
            if not parts or any(part in ("", ".", "..") for part in parts):
                raise ValueError(f"unsafe archive path: {raw_name!r}")
            if parts[0] != expected_root:
                raise ValueError(f"path outside {expected_root!r}: {raw_name!r}")

            normalized = "/".join(parts)
            if normalized in seen:
                raise ValueError(f"duplicate archive member: {raw_name!r}")
            seen.add(normalized)

            if not (member.isdir() or member.isreg()):
                raise ValueError(
                    f"unsupported archive member type for {raw_name!r}; "
                    "symbolic links, hard links, devices, and FIFOs are rejected"
                )
except (OSError, tarfile.TarError, ValueError) as error:
    print(f"Error: unsafe or unreadable archive: {error}", file=sys.stderr)
    raise SystemExit(1)

if member_count == 0:
    print("Error: archive is empty", file=sys.stderr)
    raise SystemExit(1)
PY

printf 'Extracting into the staging directory...\n'
tar --numeric-owner -xzpf "$working_archive" --no-overwrite-dir -C "$extract_dir"
staged_vw="$extract_dir/$vw_name"
[[ -d "$staged_vw" && ! -L "$staged_vw" ]] || \
    die "archive does not contain the expected directory: $vw_name"

unexpected_member=
while IFS= read -r -d '' path; do
    unexpected_member="$path"
    break
done < <(find "$staged_vw" -xdev ! \( -type f -o -type d \) -print0)
[[ -z "$unexpected_member" ]] || \
    die "restored tree contains an unsupported file type: $unexpected_member"

database_files=()
while IFS= read -r -d '' database_path; do
    database_files+=("$database_path")
done < <(find "$staged_vw" -xdev -type f -name db.sqlite3 -print0)

if [[ -n "$DATA_DIR_REL" ]]; then
    if [[ "$DATA_DIR_REL" == . ]]; then
        database_file="$staged_vw/db.sqlite3"
    else
        database_file="$staged_vw/${DATA_DIR_REL%/}/db.sqlite3"
    fi
    [[ -f "$database_file" && ! -L "$database_file" ]] || \
        die "db.sqlite3 not found under DATA_DIR_REL: $DATA_DIR_REL"
elif [[ "${#database_files[@]}" -eq 1 ]]; then
    database_file="${database_files[0]}"
else
    if [[ "${#database_files[@]}" -eq 0 ]]; then
        die 'archive does not contain db.sqlite3'
    fi
    printf 'Found multiple db.sqlite3 files:\n' >&2
    printf '  %s\n' "${database_files[@]}" >&2
    die 'set DATA_DIR_REL to the directory that is mounted at /data'
fi

database_file="$(realpath -e -- "$database_file")"
case "$database_file" in
    "$staged_vw"/*) ;;
    *) die 'db.sqlite3 resolves outside the restored Vaultwarden directory' ;;
esac
database_relative="${database_file#"$staged_vw"/}"

if [[ "$SKIP_SQLITE_CHECK" == 0 ]]; then
    command -v sqlite3 >/dev/null 2>&1 || \
        die 'sqlite3 is required; install it or explicitly set SKIP_SQLITE_CHECK=1'
    printf 'Checking SQLite database...\n'
    database_check="$(sqlite3 -readonly "$database_file" 'PRAGMA integrity_check;')" || \
        die 'SQLite integrity_check could not be completed'
    [[ "$database_check" == ok ]] || die 'SQLite integrity_check reported corruption'
else
    printf 'Warning: skipping SQLite integrity check by request.\n' >&2
fi

if [[ -n "$COMPOSE_FILE_NAME" ]]; then
    if [[ ! -e "$staged_vw/$COMPOSE_FILE_NAME" && -f "$vw_dir/$COMPOSE_FILE_NAME" && \
          ! -L "$vw_dir/$COMPOSE_FILE_NAME" ]]; then
        cp -p -- "$vw_dir/$COMPOSE_FILE_NAME" "$staged_vw/$COMPOSE_FILE_NAME"
        printf 'Notice: copied %s from the current VW_DIR.\n' "$COMPOSE_FILE_NAME"
    fi
    [[ -f "$staged_vw/$COMPOSE_FILE_NAME" && ! -L "$staged_vw/$COMPOSE_FILE_NAME" ]] || \
        die "Compose file not found: $COMPOSE_FILE_NAME"
    compose_file_name="$COMPOSE_FILE_NAME"
else
    collect_compose_files "$staged_vw"
    if [[ "${#compose_matches[@]}" -gt 1 ]]; then
        die 'the backup contains multiple Compose files; set COMPOSE_FILE_NAME'
    elif [[ "${#compose_matches[@]}" -eq 1 ]]; then
        compose_file_name="${compose_matches[0]}"
    else
        [[ -d "$vw_dir" ]] || \
            die 'the backup does not contain a Compose file and no current VW_DIR exists'
        collect_compose_files "$vw_dir"
        [[ "${#compose_matches[@]}" -eq 1 ]] || \
            die 'the current VW_DIR must contain exactly one Compose file, or set COMPOSE_FILE_NAME'
        compose_file_name="${compose_matches[0]}"
        cp -p -- "$vw_dir/$compose_file_name" "$staged_vw/$compose_file_name"
        printf 'Notice: copied %s from the current VW_DIR.\n' "$compose_file_name"
    fi
fi

if [[ -L "$staged_vw/.env" ]]; then
    die "the restored .env must not be a symbolic link: $staged_vw/.env"
fi
if [[ ! -e "$staged_vw/.env" && -f "$vw_dir/.env" && ! -L "$vw_dir/.env" ]]; then
    cp -p -- "$vw_dir/.env" "$staged_vw/.env"
    printf 'Notice: copied .env from the current VW_DIR.\n'
fi

reject_compose_overrides "$staged_vw"
printf 'Validating Compose configuration...\n'
run_compose "$staged_vw" config -q

compose_services=()
while IFS= read -r service_name; do
    [[ -n "$service_name" ]] && compose_services+=("$service_name")
done < <(run_compose "$staged_vw" config --services)
[[ "${#compose_services[@]}" -gt 0 ]] || die 'Compose configuration contains no services'

if [[ -z "$COMPOSE_SERVICE" ]]; then
    if [[ "${#compose_services[@]}" -eq 1 ]]; then
        COMPOSE_SERVICE="${compose_services[0]}"
    elif printf '%s\n' "${compose_services[@]}" | grep -Fqx vaultwarden; then
        COMPOSE_SERVICE=vaultwarden
    else
        printf 'Compose services found:\n' >&2
        printf '  %s\n' "${compose_services[@]}" >&2
        die 'set COMPOSE_SERVICE to the Vaultwarden service name'
    fi
elif ! printf '%s\n' "${compose_services[@]}" | grep -Fqx "$COMPOSE_SERVICE"; then
    die "Compose service not found: $COMPOSE_SERVICE"
fi

# Refuse to replace a container that was not identified and saved above. This
# also covers Compose-generated names such as vaultwarden-vaultwarden-1.
if ! prospective_container_ids_text="$(
    run_compose "$staged_vw" ps -a -q "$COMPOSE_SERVICE"
)"; then
    die "could not check the existing Compose service: $COMPOSE_SERVICE"
fi
prospective_container_ids=()
while IFS= read -r container_id; do
    [[ -n "$container_id" ]] && prospective_container_ids+=("$container_id")
done <<< "$prospective_container_ids_text"
[[ "${#prospective_container_ids[@]}" -le 1 ]] || \
    die "existing Compose service has multiple containers: $COMPOSE_SERVICE"
if [[ "${#prospective_container_ids[@]}" -eq 1 ]]; then
    [[ "$old_container_exists" -eq 1 && -n "$old_compose_project" && \
       "${prospective_container_ids[0]}" == "$old_container_id" ]] || \
        die "the restored Compose project would replace an untracked container: ${prospective_container_ids[0]}"
elif [[ "$old_container_exists" -eq 1 && -n "$old_compose_project" ]]; then
    die "current Compose container is not part of the restored project: $old_container_name"
fi

# A Compose-managed current container may be replaced by --force-recreate.
# Validate its original Compose file now so cleanup can faithfully rebuild the
# original stopped/running state if anything fails after the directory swap.
if [[ "$old_container_exists" -eq 1 && -n "$old_compose_project" ]]; then
    [[ -d "$vw_dir" ]] || \
        die 'the current Compose-managed container has no matching VW_DIR'
    if [[ -n "$COMPOSE_FILE_NAME" && -e "$vw_dir/$COMPOSE_FILE_NAME" ]]; then
        [[ -f "$vw_dir/$COMPOSE_FILE_NAME" && ! -L "$vw_dir/$COMPOSE_FILE_NAME" ]] || \
            die "current Compose file is not a regular file: $vw_dir/$COMPOSE_FILE_NAME"
        old_compose_file_name="$COMPOSE_FILE_NAME"
    else
        collect_compose_files "$vw_dir"
        [[ "${#compose_matches[@]}" -eq 1 ]] || \
            die 'the current VW_DIR must contain exactly one Compose file for rollback safety'
        old_compose_file_name="${compose_matches[0]}"
    fi
    reject_compose_overrides "$vw_dir"
    printf 'Validating current Compose configuration for rollback...\n'
    run_compose_file "$vw_dir" "$old_compose_file_name" config -q
    run_compose_file "$vw_dir" "$old_compose_file_name" config --services | \
        grep -Fqx "$old_compose_service" || \
        die "current Compose service not found for rollback: $old_compose_service"
fi

keep_container_stopped=1
if [[ "$old_container_exists" -eq 1 ]]; then
    if [[ "$old_container_was_running" -eq 1 ]]; then
        printf 'Stopping %s...\n' "$old_container_name"
        docker stop "$old_container_id" >/dev/null
    fi
    [[ "$(docker inspect --format '{{.State.Running}}' "$old_container_id")" == false ]] || \
        die "could not stop container: $old_container_name"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -e "$vw_dir" ]]; then
    previous_vw="${vw_dir}.before-restore-$timestamp-$$"
    [[ ! -e "$previous_vw" && ! -L "$previous_vw" ]] || \
        die "previous-data path already exists: $previous_vw"
    printf 'Preserving current Vaultwarden directory at %s...\n' "$previous_vw"
    current_move_planned=1
    mv -T -- "$vw_dir" "$previous_vw"
fi

[[ ! -e "$vw_dir" && ! -L "$vw_dir" ]] || \
    die "VW_DIR reappeared during restore: $vw_dir"
printf 'Installing restored Vaultwarden directory...\n'
new_install_attempted=1
mv -T -- "$staged_vw" "$vw_dir"

# A non-Compose container would conflict by name with the restored Compose
# deployment. Preserve it under a new name so rollback remains possible.
if [[ "$old_container_exists" -eq 1 && -z "$old_compose_project" && \
      "$old_container_name" == "$CONTAINER_NAME" ]]; then
    old_container_backup_name="${CONTAINER_NAME}-before-restore-$timestamp-$$"
    docker rename "$old_container_id" "$old_container_backup_name"
    old_container_renamed=1
fi

printf 'Creating the restored container without starting it...\n'
compose_operation_started=1
run_compose "$vw_dir" up --no-start --force-recreate --no-deps "$COMPOSE_SERVICE"

if ! restored_container_ids_text="$(
    run_compose "$vw_dir" ps -a -q "$COMPOSE_SERVICE"
)"; then
    die "could not identify the restored Compose service: $COMPOSE_SERVICE"
fi
restored_container_ids=()
while IFS= read -r container_id; do
    [[ -n "$container_id" ]] && restored_container_ids+=("$container_id")
done <<< "$restored_container_ids_text"
[[ "${#restored_container_ids[@]}" -eq 1 ]] || \
    die "restored Compose service must have exactly one container: $COMPOSE_SERVICE"
restored_container_id="${restored_container_ids[0]}"

docker inspect "$restored_container_id" >/dev/null 2>&1 || \
    die "restored Compose service did not create a usable container: $COMPOSE_SERVICE"
[[ "$(docker inspect --format '{{.State.Running}}' "$restored_container_id")" == false ]] || \
    die 'restored container started before mount validation'

if ! data_paths="$(inspect_data_mounts "$restored_container_id" "$vw_dir")"; then
    die 'restored container mount validation failed'
fi
IFS=$'\t' read -r effective_database_source effective_config_source <<< "$data_paths"
[[ -n "$effective_database_source" && -n "$effective_config_source" ]] || \
    die 'could not resolve restored /data paths'

expected_database="$vw_dir/$database_relative"
[[ -f "$effective_database_source" && ! -L "$effective_database_source" && \
   "$effective_database_source" -ef "$expected_database" ]] || \
    die 'the effective /data/db.sqlite3 mount does not point to the validated database'

if ! environment_settings="$(inspect_vaultwarden_environment "$restored_container_id")"; then
    die 'restored container environment validation failed'
fi
IFS=$'\x1f' read -r data_folder database_url config_file_setting env_file_setting \
    data_folder_file_setting database_url_file_setting config_file_file_setting \
    env_file_file_setting <<< "$environment_settings"
data_folder="${data_folder:-/data}"

[[ -z "$data_folder_file_setting" ]] || \
    die 'DATA_FOLDER_FILE is not supported by this SQLite restore script'
[[ -z "$database_url_file_setting" ]] || \
    die 'DATABASE_URL_FILE is not supported; put the SQLite path directly in Compose'
[[ -z "$config_file_file_setting" ]] || \
    die 'CONFIG_FILE_FILE is not supported; put the config path directly in Compose'
[[ -z "$env_file_file_setting" ]] || \
    die 'ENV_FILE_FILE is not supported by this SQLite restore script'
case "$data_folder" in
    /data|/data/|data|data/|./data|./data/) data_folder=/data ;;
    *) die "unsupported DATA_FOLDER in restored container: $data_folder" ;;
esac
validate_database_url "$database_url" "$data_folder" \
    'restored container DATABASE_URL' || \
    die 'restored container DATABASE_URL validation failed'
validate_config_file_path "$config_file_setting" "$data_folder" || \
    die 'restored container CONFIG_FILE validation failed'
[[ -z "$env_file_setting" ]] || \
    die 'restored container ENV_FILE is not supported; put its values directly in Compose'

config_data_folder=
config_database_url=
if [[ -f "$effective_config_source" && ! -L "$effective_config_source" ]]; then
    if ! config_settings="$(python3 - "$effective_config_source" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as config_file:
        config = json.load(config_file)
    if not isinstance(config, dict):
        raise ValueError("top-level value must be an object")
    values = [config.get("data_folder", ""), config.get("database_url", "")]
    values = ["" if value is None else value for value in values]
    if not all(isinstance(value, str) for value in values):
        raise ValueError("data_folder and database_url must be strings")
    separator = "\x1f"
    if any(separator in value or "\n" in value or "\r" in value
           for value in values):
        raise ValueError("data_folder or database_url contains a control character")
    print(separator.join(values))
except (OSError, ValueError, json.JSONDecodeError) as error:
    print(f"Error: could not validate restored config.json: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
)"; then
        die 'restored config.json is not valid JSON'
    fi
    IFS=$'\x1f' read -r config_data_folder config_database_url <<< "$config_settings"
    config_data_folder="${config_data_folder:-$data_folder}"
    case "$config_data_folder" in
        /data|/data/|data|data/|./data|./data/) config_data_folder=/data ;;
        *) die "unsupported data_folder in restored config.json: $config_data_folder" ;;
    esac
    validate_database_url "$config_database_url" "$config_data_folder" \
        'restored config.json database_url' || \
        die 'restored config.json database_url validation failed'
elif [[ -e "$effective_config_source" || -L "$effective_config_source" ]]; then
    die 'restored /data/config.json exists but is not a regular file'
fi

if [[ "$START_CONTAINER" == 1 ]]; then
    printf 'Starting restored Vaultwarden service...\n'
    run_compose "$vw_dir" start "$COMPOSE_SERVICE"

    deadline=$((SECONDS + STARTUP_TIMEOUT))
    no_health_ready_at=$((SECONDS + 5))
    while true; do
        running_state="$(docker inspect --format '{{.State.Running}}' "$restored_container_id")"
        container_status="$(docker inspect --format '{{.State.Status}}' "$restored_container_id")"
        health_status="$(docker inspect --format \
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$restored_container_id")"

        [[ "$running_state" == true ]] || \
            die "restored container is not running (status: $container_status)"
        case "$health_status" in
            healthy) break ;;
            none)
                if (( SECONDS >= no_health_ready_at )); then
                    break
                fi
                ;;
            unhealthy) die 'restored container health check failed' ;;
            starting) ;;
            *) die "unknown container health status: $health_status" ;;
        esac
        (( SECONDS < deadline )) || \
            die "container health check timed out after $STARTUP_TIMEOUT seconds"
        sleep 2
    done
    keep_container_stopped=0
else
    printf 'Restored container was created and remains stopped.\n'
fi

if ! rm -rf -- "$staging_dir"; then
    printf 'Warning: could not remove staging directory: %s\n' "$staging_dir" >&2
fi
staging_dir=
trap - EXIT INT TERM HUP

printf 'Restore complete: %s\n' "$vw_dir"
printf 'Validated database: %s\n' "$expected_database"
if [[ -n "$previous_vw" ]]; then
    printf 'Previous Vaultwarden directory preserved at: %s\n' "$previous_vw"
fi
if [[ "$old_container_renamed" -eq 1 ]]; then
    printf 'Previous standalone container preserved as: %s\n' "$old_container_backup_name"
elif [[ "$old_container_exists" -eq 1 && -z "$old_compose_project" ]]; then
    printf 'Previous standalone container remains stopped: %s\n' "$old_container_name"
fi
if [[ "$START_CONTAINER" == 1 ]]; then
    printf 'Vaultwarden is running (health: %s).\n' "$health_status"
else
    printf 'Vaultwarden remains stopped.\n'
fi
