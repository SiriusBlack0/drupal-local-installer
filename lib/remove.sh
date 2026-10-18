#!/usr/bin/env bash

# ==================================================
# Removing a project (./install.sh --remove <project>)
#
# Only projects in the registry are removed, and only the resources
# the registry lists. Every path in the record is checked against the
# path the installer itself would have created, so a changed record
# can never make the installer delete something else.
# ==================================================

REMOVE_DRY_RUN=0

# Values read from the project record (set by load_project_record).
RECORD_PROJECT_PATH=""
RECORD_PHP_VERSION=""
RECORD_DATABASE_ENGINE=""
RECORD_DATABASE_NAME=""
RECORD_DATABASE_USER=""
RECORD_SQLITE_PATH=""
RECORD_URL=""
RECORD_MANAGED_BY=""
RECORD_WEB_ROOT=""
RECORD_NGINX_ENABLED=""
RECORD_NGINX_AVAILABLE=""
RECORD_POOL=""

# Databases that belong to the server itself are never dropped.
is_system_database() {
    case "$1" in
        mysql|information_schema|performance_schema|sys|postgres|template0|template1) return 0 ;;
        *) return 1 ;;
    esac
}

get_backup_base_dir() {
    local home

    home="$(get_user_home "${PROJECT_USER:-$(id -un)}")"
    printf '%s/drupal-local-installer-backups\n' "${home:-$HOME}"
}

# Prints what exists for a project that is not in the registry, and how
# to remove it by hand. Nothing is removed automatically.
explain_unregistered_project() {
    local machine_name="$1"
    local project_path
    local found=0
    local file

    project_path="$(get_project_path "$machine_name" 2>/dev/null)" || project_path=""

    echo
    echo "[NOT REGISTERED] '$machine_name' is not in the registry."
    suggest_registered_name "$machine_name"
    echo "It was not created by this installer, or it was created before the"
    echo "registry existed. To stay safe, nothing is removed automatically."
    echo
    echo "Found on this system:"

    if [[ -n "$project_path" && -e "$project_path" ]]; then
        echo "  - project directory: $project_path"
        found=1
    fi

    for file in /etc/nginx/sites-enabled/"$machine_name".conf \
                /etc/nginx/sites-available/"$machine_name".conf \
                /etc/php/*/fpm/pool.d/"$machine_name".conf; do
        if [[ -e "$file" || -L "$file" ]]; then
            echo "  - $file"
            found=1
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        echo "  nothing with this name."
        return 0
    fi

    echo
    echo "Remove by hand (back up first: the data cannot be recovered):"
    echo "  sudo rm -f /etc/nginx/sites-enabled/$machine_name.conf /etc/nginx/sites-available/$machine_name.conf"
    echo "  sudo nginx -t && sudo systemctl reload nginx"
    echo "  sudo rm -f /etc/php/<php>/fpm/pool.d/$machine_name.conf"
    echo "  sudo php-fpm<php> -t && sudo systemctl reload php<php>-fpm"
    echo "  # the database and its user, if the project had one (see README.md)"
    [[ -n "$project_path" ]] && echo "  sudo rm -rf -- '$project_path'"
}

# Reads and checks the record. Any value that does not match what the
# installer would have created stops the removal.
load_project_record() {
    local machine_name="$1"
    local record="$2"
    local expected_path

    if [[ "$(read_project_field "$record" machine_name)" != "$machine_name" ]]; then
        echo "[ERROR] The record does not belong to '$machine_name': $record"
        return 1
    fi

    RECORD_PROJECT_PATH="$(read_project_field "$record" project_path)" || RECORD_PROJECT_PATH=""
    RECORD_PHP_VERSION="$(read_project_field "$record" php_version)" || RECORD_PHP_VERSION=""
    RECORD_DATABASE_ENGINE="$(read_project_field "$record" database_engine)" || RECORD_DATABASE_ENGINE=""
    RECORD_DATABASE_NAME="$(read_project_field "$record" database_name)" || RECORD_DATABASE_NAME=""
    RECORD_DATABASE_USER="$(read_project_field "$record" database_user)" || RECORD_DATABASE_USER=""
    RECORD_SQLITE_PATH="$(read_project_field "$record" sqlite_path)" || RECORD_SQLITE_PATH=""
    RECORD_URL="$(read_project_field "$record" url)" || RECORD_URL=""
    RECORD_MANAGED_BY="$(read_project_field "$record" managed_by)" || RECORD_MANAGED_BY="installer"
    RECORD_WEB_ROOT="$(read_project_field "$record" web_root)" || RECORD_WEB_ROOT=""
    RECORD_NGINX_ENABLED="$(read_project_field "$record" nginx_enabled)" || RECORD_NGINX_ENABLED=""
    RECORD_NGINX_AVAILABLE="$(read_project_field "$record" nginx_available)" || RECORD_NGINX_AVAILABLE=""
    RECORD_POOL="$(read_project_field "$record" php_fpm_pool)" || RECORD_POOL=""

    if [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        load_adopted_record
        return
    fi

    expected_path="$(get_project_path "$machine_name")" || return 1

    if [[ "$RECORD_PROJECT_PATH" != "$expected_path" ]] ||
       ! is_managed_project_path "$RECORD_PROJECT_PATH"; then
        echo "[ERROR] Unexpected project path in the record: '$RECORD_PROJECT_PATH'"
        echo "        Expected: $expected_path. Nothing was removed."
        return 1
    fi

    if [[ ! "$RECORD_PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] ||
       [[ "$(read_project_field "$record" php_fpm_pool)" != "$(get_php_fpm_pool_config_path "$machine_name" "$RECORD_PHP_VERSION")" ]] ||
       [[ "$(read_project_field "$record" nginx_available)" != "$(get_nginx_config_path "$machine_name")" ]] ||
       [[ "$(read_project_field "$record" nginx_enabled)" != "$(get_nginx_enabled_path "$machine_name")" ]]; then
        echo "[ERROR] Unexpected PHP-FPM or Nginx path in the record. Nothing was removed."
        return 1
    fi

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql|postgresql)
            if ! is_valid_database_name "$RECORD_DATABASE_NAME" ||
               ! is_valid_database_user "$RECORD_DATABASE_USER"; then
                echo "[ERROR] Invalid database name or user in the record. Nothing was removed."
                return 1
            fi
            ;;
        sqlite)
            if [[ "$RECORD_SQLITE_PATH" != "$RECORD_PROJECT_PATH/"* ]]; then
                echo "[ERROR] The SQLite file in the record is outside the project. Nothing was removed."
                return 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown database engine in the record: '$RECORD_DATABASE_ENGINE'"
            return 1
            ;;
    esac
}

# Checks for projects found by --scan: every path must be where such a
# file can be, and shared resources are never accepted.
load_adopted_record() {
    local base_dir
    local php_etc

    base_dir="$(get_projects_base_dir)" || return 1
    php_etc="$(get_php_etc_dir)"

    if [[ "$(dirname "$RECORD_PROJECT_PATH")" != "$base_dir" ||
          "$(basename "$RECORD_PROJECT_PATH")" == "." ||
          "$(basename "$RECORD_PROJECT_PATH")" == ".." ||
          "$RECORD_PROJECT_PATH" == *$'\n'* || -L "$RECORD_PROJECT_PATH" ]]; then
        echo "[ERROR] Unexpected project path in the record: '$RECORD_PROJECT_PATH'"
        echo "        Adopted projects must be directly in $base_dir. Nothing was removed."
        return 1
    fi

    if [[ -n "$RECORD_NGINX_ENABLED" && "$(dirname "$RECORD_NGINX_ENABLED")" != "$(get_nginx_sites_enabled_dir)" ]] ||
       [[ -n "$RECORD_NGINX_AVAILABLE" && "$(dirname "$RECORD_NGINX_AVAILABLE")" != "$(get_nginx_sites_available_dir)" ]]; then
        echo "[ERROR] Unexpected Nginx path in the record. Nothing was removed."
        return 1
    fi

    if [[ -n "$RECORD_POOL" ]] &&
       { [[ ! "$RECORD_POOL" =~ ^${php_etc}/[0-9]+\.[0-9]+/fpm/pool\.d/[^/]+\.conf$ ]] ||
         [[ "$(basename "$RECORD_POOL")" == "www.conf" ]]; }; then
        echo "[ERROR] Unexpected PHP-FPM pool in the record. Nothing was removed."
        return 1
    fi

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql|postgresql)
            if ! is_valid_database_name "$RECORD_DATABASE_NAME" || is_system_database "$RECORD_DATABASE_NAME"; then
                echo "[ERROR] Invalid database name in the record. Nothing was removed."
                return 1
            fi
            ;;
        sqlite|unknown) ;;
        *)
            echo "[ERROR] Unknown database engine in the record: '$RECORD_DATABASE_ENGINE'"
            return 1
            ;;
    esac
}

describe_presence() {
    if [[ -e "$1" || -L "$1" ]]; then
        echo "exists"
    else
        echo "already gone"
    fi
}

# Warns about work that exists only in this directory.
warn_about_git_changes() {
    local project_path="$1"
    local changes

    [[ -d "$project_path/.git" ]] || return 0

    changes="$(git -C "$project_path" status --porcelain 2>/dev/null | wc -l)"

    if [[ "$changes" -gt 0 ]]; then
        echo "[WARNING] The project is a git repository with $changes uncommitted change(s)."
    fi

    if git -C "$project_path" rev-parse --abbrev-ref '@{upstream}' > /dev/null 2>&1; then
        changes="$(git -C "$project_path" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"

        if [[ "$changes" -gt 0 ]]; then
            echo "[WARNING] $changes commit(s) were never pushed."
        fi
    elif git -C "$project_path" rev-parse HEAD > /dev/null 2>&1; then
        echo "[WARNING] The git repository has no remote branch: its commits exist only here."
    fi
}

print_removal_plan() {
    local machine_name="$1"
    local record="$2"
    local size

    size="$(du -sh "$RECORD_PROJECT_PATH" 2>/dev/null | cut -f1)" || size=""

    echo
    echo "======================================"
    echo "  Remove project: $machine_name"
    echo "======================================"
    echo
    echo "Site: $RECORD_URL"
    echo
    if [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        echo "Type: adopted (found by --scan, not created by this installer)"
        echo
    fi

    echo "Will be removed:"

    if [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        if [[ -n "$RECORD_NGINX_ENABLED" ]]; then
            echo "  - Nginx site:     $RECORD_NGINX_ENABLED ($(describe_presence "$RECORD_NGINX_ENABLED"))"
            [[ -n "$RECORD_NGINX_AVAILABLE" && "$RECORD_NGINX_AVAILABLE" != "$RECORD_NGINX_ENABLED" ]] &&
                echo "                    $RECORD_NGINX_AVAILABLE ($(describe_presence "$RECORD_NGINX_AVAILABLE"))"
        fi

        if [[ -n "$RECORD_POOL" ]]; then
            echo "  - PHP-FPM pool:   $RECORD_POOL ($(describe_presence "$RECORD_POOL"))"
        else
            echo "  - PHP-FPM pool:   shared with other projects: not touched"
        fi

        case "$RECORD_DATABASE_ENGINE" in
            sqlite) echo "  - Database:       SQLite file ${RECORD_SQLITE_PATH}" ;;
            unknown) echo "  - Database:       unknown: not touched (remove it by hand if needed)" ;;
            *) echo "  - Database:       $RECORD_DATABASE_ENGINE database '$RECORD_DATABASE_NAME'"
               echo "                    (the user '$RECORD_DATABASE_USER' is kept: it may be shared)" ;;
        esac
    else
        echo "  - Nginx site:     $(get_nginx_enabled_path "$machine_name") ($(describe_presence "$(get_nginx_enabled_path "$machine_name")"))"
        echo "                    $(get_nginx_config_path "$machine_name") ($(describe_presence "$(get_nginx_config_path "$machine_name")"))"
        echo "  - PHP-FPM pool:   $(get_php_fpm_pool_config_path "$machine_name" "$RECORD_PHP_VERSION") ($(describe_presence "$(get_php_fpm_pool_config_path "$machine_name" "$RECORD_PHP_VERSION")"))"

        if [[ "$RECORD_DATABASE_ENGINE" == "sqlite" ]]; then
            echo "  - Database:       SQLite file inside the project directory"
        else
            echo "  - Database:       $RECORD_DATABASE_ENGINE database '$RECORD_DATABASE_NAME' and user '$RECORD_DATABASE_USER'"
        fi
    fi

    echo "  - Project folder: $RECORD_PROJECT_PATH (${size:-?}, $(describe_presence "$RECORD_PROJECT_PATH"))"
    echo "  - Registry entry: $record"
    echo
    echo "Not touched: installed packages, running services, other projects,"
    echo "the installation logs."
    echo
    echo "WARNING: everything that is not backed up is lost for good:"
    echo "  the database content, uploaded files (web/sites/default/files),"
    echo "  and any code or configuration changed in this project."

    if [[ -d "$RECORD_PROJECT_PATH" ]]; then
        warn_about_git_changes "$RECORD_PROJECT_PATH"
    fi
}

# Backup: database dump and the project directory without vendor/
# (Composer recreates it). Both are made with sudo, so they work for any
# project (also Drupal 7, also without Drush) without the database
# password. The files are written by the developer, mode 600.
dump_database_to() {
    local file="$1"
    local status

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            sudo mysqldump --single-transaction --routines --triggers -- "$RECORD_DATABASE_NAME" | gzip > "$file"
            status=("${PIPESTATUS[@]}")
            ;;
        postgresql)
            sudo -u postgres pg_dump -- "$RECORD_DATABASE_NAME" | gzip > "$file"
            status=("${PIPESTATUS[@]}")
            ;;
        *)
            return 0
            ;;
    esac

    [[ "${status[0]}" -eq 0 && "${status[1]}" -eq 0 && -s "$file" ]]
}

create_project_backup() {
    local machine_name="$1"
    local backup_dir
    local base_dir
    local folder

    backup_dir="$(get_backup_base_dir)/${machine_name}-$(date +%Y%m%d-%H%M%S)"
    base_dir="$(dirname "$RECORD_PROJECT_PATH")"
    folder="$(basename "$RECORD_PROJECT_PATH")"

    if ! run_as_project_user "$PROJECT_USER" install -d -m 0700 "$backup_dir"; then
        echo "[ERROR] Could not create the backup directory: $backup_dir"
        return 1
    fi

    (
        umask 077

        case "$RECORD_DATABASE_ENGINE" in
            mariadb|mysql|postgresql)
                printf 'Backing up the database ... '

                if ! dump_database_to "$backup_dir/database.sql.gz"; then
                    echo "FAILED"
                    echo "[ERROR] Database backup failed. Nothing was removed."
                    exit 1
                fi

                echo "OK"
                ;;
        esac

        printf 'Backing up the project files ... '

        # Intended: tar reads as root, the archive is written by the developer.
        # shellcheck disable=SC2024
        if ! sudo tar -czf - -C "$base_dir" --exclude="$folder/vendor" -- "$folder" > "$backup_dir/project.tar.gz"; then
            echo "FAILED"
            echo "[ERROR] File backup failed. Nothing was removed."
            exit 1
        fi

        echo "OK"
    ) || return 1

    echo "[OK] Backup saved: $backup_dir ($(du -sh "$backup_dir" 2>/dev/null | cut -f1))"
}

# Asks the yes/no backup question. Returns 0 for a backup, 1 for none,
# 2 when the input ends (cancel).
ask_for_backup() {
    local answer

    while true; do
        echo
        if ! read -r -p "Create a backup before removing? [Y/n]: " answer; then
            echo
            return 2
        fi

        case "$answer" in
            y|Y|"") return 0 ;;
            n|N) return 1 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

confirm_removal() {
    local machine_name="$1"
    local answer

    echo
    echo "This cannot be undone. Type the project name to confirm."

    if ! read -r -p "Project name ($machine_name): " answer; then
        echo
        return 1
    fi

    [[ "$answer" == "$machine_name" ]]
}

# Removes the parts of an adopted project. Shared resources are never
# in the record (see lib/scan.sh) and the database user is kept.
remove_adopted_parts() {
    local failed=0
    local php_version=""

    if [[ -n "$RECORD_NGINX_ENABLED" ]]; then
        if [[ ( -e "$RECORD_NGINX_ENABLED" || -L "$RECORD_NGINX_ENABLED" ) &&
              "$(find_nginx_site_for_root "$RECORD_WEB_ROOT")" != "$RECORD_NGINX_ENABLED" ]]; then
            echo "[SKIPPED] $RECORD_NGINX_ENABLED no longer serves $RECORD_WEB_ROOT: left in place"
        elif sudo rm -f -- "$RECORD_NGINX_ENABLED" ${RECORD_NGINX_AVAILABLE:+"$RECORD_NGINX_AVAILABLE"} &&
             sudo nginx -t > /dev/null 2>&1 && reload_or_start_service nginx > /dev/null 2>&1; then
            echo "[OK] Nginx site removed"
        else
            echo "[FAILED] Nginx site (check: sudo nginx -t)"
            failed=1
        fi
    fi

    if [[ -n "$RECORD_POOL" ]]; then
        php_version="$(basename "$(dirname "$(dirname "$(dirname "$RECORD_POOL")")")")"

        if sudo rm -f -- "$RECORD_POOL" &&
           sudo "php-fpm${php_version}" -t > /dev/null 2>&1 &&
           reload_or_start_service "php${php_version}-fpm" > /dev/null 2>&1; then
            echo "[OK] PHP-FPM pool removed"
        else
            echo "[FAILED] PHP-FPM pool $RECORD_POOL"
            failed=1
        fi
    fi

    case "$RECORD_DATABASE_ENGINE" in
        mariadb|mysql)
            if printf '%s\n' "DROP DATABASE IF EXISTS \`${RECORD_DATABASE_NAME}\`;" | sudo mysql; then
                echo "[OK] Database '$RECORD_DATABASE_NAME' removed (user '$RECORD_DATABASE_USER' kept)"
            else
                echo "[FAILED] Database '$RECORD_DATABASE_NAME'"
                failed=1
            fi
            ;;
        postgresql)
            if drop_postgresql_database "$RECORD_DATABASE_NAME" > /dev/null; then
                echo "[OK] Database '$RECORD_DATABASE_NAME' removed (user '$RECORD_DATABASE_USER' kept)"
            else
                echo "[FAILED] Database '$RECORD_DATABASE_NAME'"
                failed=1
            fi
            ;;
    esac

    if [[ ! -e "$RECORD_PROJECT_PATH" ]] || sudo rm -rf -- "$RECORD_PROJECT_PATH"; then
        echo "[OK] Project folder removed"
    else
        echo "[FAILED] Project folder $RECORD_PROJECT_PATH"
        failed=1
    fi

    return "$failed"
}

remove_registered_project() {
    local machine_name="$1"
    local record="$2"
    local failed=0

    echo
    echo "Removing $machine_name..."

    if [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        remove_adopted_parts || failed=1
        finish_removal "$machine_name" "$record" "$failed"
        return
    fi

    if remove_nginx_site "$machine_name"; then
        echo "[OK] Nginx site removed"
    else
        echo "[FAILED] Nginx site"
        failed=1
    fi

    if remove_php_fpm_pool "$machine_name" "$RECORD_PHP_VERSION"; then
        echo "[OK] PHP-FPM pool removed"
    else
        echo "[FAILED] PHP-FPM pool"
        failed=1
    fi

    if [[ "$RECORD_DATABASE_ENGINE" == "sqlite" ]]; then
        echo "[OK] SQLite database is removed with the project folder"
    elif remove_project_database "$RECORD_DATABASE_ENGINE" "$RECORD_DATABASE_NAME" "$RECORD_DATABASE_USER" > /dev/null; then
        echo "[OK] Database '$RECORD_DATABASE_NAME' and user '$RECORD_DATABASE_USER' removed"
    else
        echo "[FAILED] Database '$RECORD_DATABASE_NAME' / user '$RECORD_DATABASE_USER'"
        failed=1
    fi

    if [[ ! -e "$RECORD_PROJECT_PATH" ]] || remove_project_directory "$RECORD_PROJECT_PATH"; then
        echo "[OK] Project folder removed"
    else
        echo "[FAILED] Project folder $RECORD_PROJECT_PATH"
        failed=1
    fi

    finish_removal "$machine_name" "$record" "$failed"
}

# The registry entry goes last, and only when everything else is gone,
# so a failed removal can simply be run again.
finish_removal() {
    local machine_name="$1"
    local record="$2"
    local failed="$3"

    if [[ "$failed" -ne 0 ]]; then
        echo
        echo "[ERROR] Some parts could not be removed (see above)."
        echo "        The registry entry is kept: run --remove again after fixing the cause."
        return 1
    fi

    if rm -f -- "$record"; then
        echo "[OK] Registry entry removed"
    fi

    echo
    echo "[DONE] $machine_name was removed."
}

run_remove_project() {
    local name="$1"
    local machine_name
    local record
    local backup_status=0

    machine_name="$(get_project_machine_name "$name")"

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project name: '$name'"
        return 1
    fi

    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        explain_unregistered_project "$machine_name"
        return 1
    fi

    acquire_project_lock "$machine_name" || return 1
    load_project_record "$machine_name" "$record" || return 1
    print_removal_plan "$machine_name" "$record"

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "[DRY RUN] Nothing was changed."
        return 0
    fi

    ask_for_backup || backup_status=$?

    case "$backup_status" in
        0)
            if [[ ! -d "$RECORD_PROJECT_PATH" ]]; then
                echo "[ERROR] The project folder is gone, so there is nothing to back up."
                echo "        Answer 'n' to remove the remaining parts."
                return 1
            fi
            ;;
        1)
            echo "[INFO] No backup."
            ;;
        *)
            echo "Removal cancelled."
            return 1
            ;;
    esac

    if ! confirm_removal "$machine_name"; then
        echo "Name does not match. Removal cancelled; nothing was removed."
        return 1
    fi

    require_sudo || return 1

    if [[ "$backup_status" -eq 0 ]]; then
        create_project_backup "$machine_name" || return 1
    fi

    remove_registered_project "$machine_name" "$record"
}

# Removes only the registry entry (./install.sh --unregister NAME).
# Nothing on the system is touched.
run_unregister_project() {
    local machine_name
    local record

    machine_name="$(get_project_machine_name "$1")"
    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        echo "[ERROR] '$machine_name' is not in the registry."
        return 1
    fi

    rm -f -- "$record"
    echo "[OK] '$machine_name' removed from the registry. Nothing else was changed."
}
