#!/usr/bin/env bash

# --------------------------------------------------
# Project Registry
# --------------------------------------------------

# One file per project, readable only by the owner. The record holds
# everything needed to manage the project later (remove, update), but
# never a password: the database is managed through sudo, and the
# database password is only in the project's own settings.local.php
# (settings.php in projects made before it, and in adopted ones).
REGISTRY_FORMAT=1

# Filled by lib/scan.sh for adopted projects; empty for new projects.
declare -gA REGISTRY_VALUES=()

REGISTRY_FIELDS=(
    format
    managed_by
    support
    name
    machine_name
    created
    owner
    project_path
    web_root
    url
    drupal_version
    install_profile
    php_version
    database_engine
    database_name
    database_user
    sqlite_path
    php_fpm_pool
    php_fpm_socket
    nginx_available
    nginx_enabled
    log_file
)

get_user_home() {
    getent passwd "$1" | cut -d: -f6
}

# The registry belongs to the developer, also when the installer was
# started with sudo (then $HOME may be root's home).
get_registry_directory() {
    local base
    local home

    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        base="$XDG_DATA_HOME"
    elif [[ -n "${PROJECT_USER:-}" ]] &&
         home="$(get_user_home "$PROJECT_USER")" && [[ -n "$home" ]]; then
        base="$home/.local/share"
    else
        base="$HOME/.local/share"
    fi

    printf '%s\n' "$base/drupal-local-installer/projects"
}

get_project_record_path() {
    local machine_name="$1"

    [[ "$machine_name" =~ ^[a-z0-9_]+$ ]] || return 1
    printf '%s/%s.conf\n' "$(get_registry_directory)" "$machine_name"
}

# --------------------------------------------------
# Check whether a project is registered
# --------------------------------------------------

is_project_registered() {
    local machine_name="$1"
    local registry_directory

    [[ "$machine_name" =~ ^[a-z0-9_]+$ ]] || return 2

    registry_directory="$(get_registry_directory)"

    [ -f "$registry_directory/${machine_name}.conf" ]
}

# --------------------------------------------------
# Project location
# --------------------------------------------------

# Base directory for all projects. Defaults to /var/www and can be
# overridden with DRUPAL_PROJECTS_DIR (absolute path).
get_projects_base_dir() {
    local base_dir="${DRUPAL_PROJECTS_DIR:-/var/www}"

    if [[ "$base_dir" != /* ]]; then
        echo "[ERROR] DRUPAL_PROJECTS_DIR must be an absolute path: $base_dir" >&2
        return 1
    fi

    printf '%s\n' "${base_dir%/}"
}

get_project_path() {
    local machine_name="$1"
    local base_dir

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project machine name: $machine_name" >&2
        return 1
    fi

    base_dir="$(get_projects_base_dir)" || return 1

    printf '%s/%s\n' "$base_dir" "$machine_name"
}

# --------------------------------------------------
# Check whether a project directory already exists
# --------------------------------------------------

is_project_directory_taken() {
    local project_path="$1"

    [ -e "$project_path" ] || [ -L "$project_path" ]
}

# --------------------------------------------------
# Check whether an Nginx configuration already exists
# --------------------------------------------------

is_nginx_config_taken() {
    local machine_name="$1"

    [[ "$machine_name" =~ ^[a-z0-9_]+$ ]] || return 2

    [ -e "/etc/nginx/sites-available/${machine_name}.conf" ] ||
    [ -L "/etc/nginx/sites-available/${machine_name}.conf" ] ||
    [ -e "/etc/nginx/sites-enabled/${machine_name}.conf" ] ||
    [ -L "/etc/nginx/sites-enabled/${machine_name}.conf" ]
}

# --------------------------------------------------
# Describe the first conflict for a new project
# --------------------------------------------------

# Prints why the project cannot be created and returns 0 when a
# conflict exists; returns 1 when the name is free to use.
get_project_conflict() {
    local machine_name="$1"
    local project_path="$2"

    if is_project_registered "$machine_name"; then
        echo "Project '$machine_name' is already registered."
        return 0
    fi

    if is_project_directory_taken "$project_path"; then
        echo "Project directory '$project_path' already exists."
        return 0
    fi

    if is_nginx_config_taken "$machine_name"; then
        echo "Nginx configuration for '$machine_name' already exists."
        return 0
    fi

    return 1
}

# --------------------------------------------------
# Writing and reading project records
# --------------------------------------------------

# Prints the value for one registry field from the current installation.
# The upper-case variables are set by lib/ui.sh during the questions.
# shellcheck disable=SC2153
get_registry_value() {
    # Values set by --scan for projects the installer did not create.
    if [[ -n "${REGISTRY_VALUES[$1]+set}" ]]; then
        printf '%s\n' "${REGISTRY_VALUES[$1]}"
        return 0
    fi

    case "$1" in
        format) echo "$REGISTRY_FORMAT" ;;
        managed_by) echo "installer" ;;
        support) echo "supported" ;;
        web_root) echo "$PROJECT_PATH/web" ;;
        name) echo "$PROJECT_NAME" ;;
        machine_name) echo "$PROJECT_MACHINE_NAME" ;;
        created) date --iso-8601=seconds ;;
        owner) echo "$PROJECT_USER" ;;
        project_path) echo "$PROJECT_PATH" ;;
        url) echo "http://$(get_project_nginx_domain "$PROJECT_MACHINE_NAME")" ;;
        drupal_version) echo "$DRUPAL_VERSION" ;;
        install_profile) echo "${DRUPAL_INSTALL_PROFILE:-standard}" ;;
        php_version) echo "$PHP_VERSION" ;;
        database_engine) echo "$DATABASE_ENGINE" ;;
        database_name) [[ "$DATABASE_ENGINE" == "sqlite" ]] || echo "$DATABASE_NAME" ;;
        database_user) [[ "$DATABASE_ENGINE" == "sqlite" ]] || echo "$DATABASE_USER" ;;
        sqlite_path) [[ "$DATABASE_ENGINE" != "sqlite" ]] || echo "$SQLITE_DATABASE_PATH" ;;
        php_fpm_pool) get_php_fpm_pool_config_path "$PROJECT_MACHINE_NAME" "$PHP_VERSION" ;;
        php_fpm_socket) get_project_php_fpm_socket "$PROJECT_MACHINE_NAME" "$PHP_VERSION" ;;
        nginx_available) get_nginx_config_path "$PROJECT_MACHINE_NAME" ;;
        nginx_enabled) get_nginx_enabled_path "$PROJECT_MACHINE_NAME" ;;
        log_file) echo "${LOG_FILE:-}" ;;
        *) return 1 ;;
    esac
}

generate_project_record() {
    local field
    local value

    echo "# drupal-local-installer project record (no passwords are stored here)."

    for field in "${REGISTRY_FIELDS[@]}"; do
        value="$(get_registry_value "$field")" || return 1

        if [[ "$value" == *$'\n'* ]]; then
            echo "[ERROR] Invalid value for $field" >&2
            return 1
        fi

        printf '%s=%s\n' "$field" "$value"
    done
}

# Writes the record atomically (temporary file, then rename), mode 600,
# owned by the developer. An existing record is never replaced.
write_project_record() {
    local record_path
    local registry_dir
    local record
    local temp_file

    record_path="$(get_project_record_path "$PROJECT_MACHINE_NAME")" || return 1
    registry_dir="$(dirname "$record_path")"

    if [[ -e "$record_path" ]]; then
        echo "[ERROR] Project record already exists: $record_path"
        return 1
    fi

    record="$(generate_project_record)" || return 1
    temp_file="$registry_dir/.${PROJECT_MACHINE_NAME}.conf.tmp"

    if ! run_as_project_user "$PROJECT_USER" install -d -m 0700 "$registry_dir" ||
       ! printf '%s\n' "$record" |
            run_as_project_user "$PROJECT_USER" tee "$temp_file" > /dev/null ||
       ! run_as_project_user "$PROJECT_USER" chmod 0600 "$temp_file" ||
       ! run_as_project_user "$PROJECT_USER" mv -n "$temp_file" "$record_path"; then
        rm -f "$temp_file" 2>/dev/null
        echo "[ERROR] Could not write the project record: $record_path"
        return 1
    fi

    echo "[OK] Project registered: $record_path"
}

# Reads one field. The file is parsed as data, never executed, so a
# changed record cannot run commands.
read_project_field() {
    local record_path="$1"
    local wanted="$2"
    local key
    local value

    [[ -f "$record_path" ]] || return 1

    while IFS='=' read -r key value; do
        if [[ "$key" == "$wanted" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$record_path"

    return 1
}

# One run at a time per project: --update, --php and --remove take this
# lock, so a second run on the same project stops instead of changing it
# at the same time. The lock is released when the process ends, even
# after Ctrl+C or a crash (flock).
acquire_project_lock() {
    local machine_name="$1"
    local lock_dir
    local lock_fd

    [[ "$machine_name" =~ ^[a-z0-9_]+$ ]] || return 1
    command -v flock > /dev/null || return 0

    # Already held by this process (or the shell it was started from).
    [[ " ${PROJECT_LOCKS_HELD:-} " == *" $machine_name "* ]] && return 0

    lock_dir="$(dirname "$(get_log_directory)")/locks"
    mkdir -p "$lock_dir" 2>/dev/null && chmod 700 "$lock_dir" 2>/dev/null || return 0

    # The descriptor stays open until the process ends.
    exec {lock_fd}>> "$lock_dir/$machine_name.lock" || return 0

    if ! flock -n "$lock_fd"; then
        echo "[BLOCKED] Another run of the installer is working on '$machine_name' right now."
        echo "          Wait for it to finish, then try again."
        return 1
    fi

    PROJECT_LOCKS_HELD="${PROJECT_LOCKS_HELD:-} $machine_name"
}

# "Did you mean ...?" for a mistyped project name: registered names at
# most 2 edits away (Levenshtein distance), or that contain the name.
suggest_registered_name() {
    local wanted="$1"
    local record
    local name
    local -a names=()
    local match

    for record in "$(get_registry_directory 2>/dev/null)"/*.conf; do
        [[ -f "$record" ]] || continue
        name="$(read_project_field "$record" machine_name)" || continue
        names+=("$name")
    done

    [[ "${#names[@]}" -gt 0 ]] || return 0

    match="$(printf '%s\n' "${names[@]}" | awk -v w="$wanted" '
        function lev(a, b,    i, j, la, lb, d, cost, x) {
            la = length(a); lb = length(b)
            for (i = 0; i <= la; i++) d[i, 0] = i
            for (j = 0; j <= lb; j++) d[0, j] = j
            for (i = 1; i <= la; i++)
                for (j = 1; j <= lb; j++) {
                    cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
                    x = d[i - 1, j] + 1
                    if (d[i, j - 1] + 1 < x) x = d[i, j - 1] + 1
                    if (d[i - 1, j - 1] + cost < x) x = d[i - 1, j - 1] + cost
                    d[i, j] = x
                }
            return d[la, lb]
        }
        $0 != w && (lev($0, w) <= 2 || (length(w) >= 3 && index($0, w) > 0)) { print }
    ' | head -n 3 | paste -sd ',' - | sed 's/,/, /g')"

    if [[ -n "$match" ]]; then
        echo "        Did you mean: $match ?"
    fi
}

# Changes one field of a record (atomic: temporary file, then rename).
# Values with a newline are refused.
set_project_field() {
    local record_path="$1"
    local field="$2"
    local value="$3"
    local temp_file

    [[ -f "$record_path" && "$field" =~ ^[a-z_]+$ && "$value" != *$'\n'* ]] || return 1

    temp_file="$(dirname "$record_path")/.$(basename "$record_path").tmp"

    if ! awk -v key="$field" -v value="$value" '
            BEGIN { done = 0 }
            index($0, key "=") == 1 { print key "=" value; done = 1; next }
            { print }
            END { if (!done) print key "=" value }
        ' "$record_path" | run_as_project_user "$PROJECT_USER" tee "$temp_file" > /dev/null ||
       ! run_as_project_user "$PROJECT_USER" chmod 0600 "$temp_file" ||
       ! run_as_project_user "$PROJECT_USER" mv -f "$temp_file" "$record_path"; then
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
}

list_registered_projects() {
    local registry_dir
    local record
    local found=0
    local machine_name
    local project_path
    local state

    registry_dir="$(get_registry_directory)"

    echo
    echo "Registered projects ($registry_dir):"
    echo

    for record in "$registry_dir"/*.conf; do
        [[ -f "$record" ]] || continue

        if [[ "$found" -eq 0 ]]; then
            printf '%-20s %-34s %-5s %-11s %-9s %s\n' "PROJECT" "URL" "PHP" "DATABASE" "TYPE" "STATE"
            found=1
        fi

        machine_name="$(read_project_field "$record" machine_name)" || machine_name="?"
        project_path="$(read_project_field "$record" project_path)" || project_path=""

        if [[ -z "$project_path" || ! -d "$project_path" ]]; then
            state="directory missing"
        else
            case "$(read_project_field "$record" support)" in
                unsupported*) state="$(read_project_field "$record" support)" ;;
                php_missing*) state="$(read_project_field "$record" support)" ;;
                *) state="ok" ;;
            esac
        fi

        printf '%-20s %-34s %-5s %-11s %-9s %s\n' \
            "$machine_name" \
            "$(read_project_field "$record" url)" \
            "$(read_project_field "$record" php_version | grep . || echo "?")" \
            "$(read_project_field "$record" database_engine)" \
            "$(read_project_field "$record" managed_by || echo installer)" \
            "$state"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No projects registered yet."
    fi
}
