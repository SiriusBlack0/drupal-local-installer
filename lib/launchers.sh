#!/usr/bin/env bash

# ==================================================
# Launchers for a registered project (--launchers NAME)
#
# Projects made by the installer have ./start, ./drush and ./composer.
# Adopted projects (--scan) do not: there "vendor/bin/drush" and
# "composer" run with the system's default PHP, which may not be the
# project's. --launchers writes the missing ones, after asking:
# - only files in the project folder (and .git/info/exclude, which is
#   for this computer only); Nginx, pools and settings stay as they are;
# - an existing file is never replaced;
# - a drush/ folder (custom Drush commands) means no ./drush.
# ==================================================

LAUNCHER_PLAN_WRITE=()
LAUNCHER_PLAN_NOTES=()

# The values ./start and ./drush need for this project: the installer's
# names for its own projects, the registered ones for adopted projects.
# Prints "url|site_config|socket|error_log" (socket may be empty).
get_launcher_values() {
    local record="$1"
    local machine_name="$2"
    local url
    local site
    local socket
    local error_log=""
    local site_file

    if [[ "$RECORD_MANAGED_BY" != "adopted" ]]; then
        printf '%s|%s|%s|%s\n' \
            "http://$(get_project_nginx_domain "$machine_name")" \
            "/etc/nginx/sites-enabled/${machine_name}.conf" \
            "$(get_project_php_fpm_socket "$machine_name" "$RECORD_PHP_VERSION")" \
            "/var/log/nginx/${machine_name}.error.log"
        return 0
    fi

    url="$RECORD_URL"
    site="$RECORD_NGINX_ENABLED"
    socket="$(read_project_field "$record" php_fpm_socket)" || socket=""
    socket="${socket#unix:}"
    # A TCP pool (127.0.0.1:9000) has no socket file to check.
    [[ "$socket" == /* ]] || socket=""

    if [[ -n "$site" ]] && site_file="$(readlink -f "$site" 2>/dev/null)" && [[ -f "$site_file" ]]; then
        error_log="$(get_nginx_directive "$site_file" error_log | awk '{ print $1 }')"
    fi

    [[ "$error_log" == /* ]] || error_log="/var/log/nginx/error.log"

    printf '%s|%s|%s|%s\n' "$url" "$site" "$socket" "$error_log"
}

# Decides what can be written: LAUNCHER_PLAN_WRITE (start, drush,
# composer) and LAUNCHER_PLAN_NOTES (why something is not written).
plan_launchers() {
    local path="$RECORD_PROJECT_PATH"
    local url="$1"

    LAUNCHER_PLAN_WRITE=()
    LAUNCHER_PLAN_NOTES=()

    if [[ -e "$path/start" || -L "$path/start" ]]; then
        LAUNCHER_PLAN_NOTES+=("./start exists already; kept")
    elif [[ -z "$url" ]]; then
        LAUNCHER_PLAN_NOTES+=("./start: no Nginx site was found for this project, so there is nothing to start for it")
    elif ! get_database_service_name "$RECORD_DATABASE_ENGINE" > /dev/null 2>&1; then
        LAUNCHER_PLAN_NOTES+=("./start: the project's database is unknown")
    else
        LAUNCHER_PLAN_WRITE+=(start)
    fi

    if [[ -d "$path/drush" && ! -L "$path/drush" ]]; then
        LAUNCHER_PLAN_NOTES+=("./drush: the project has a drush/ folder (custom Drush commands), so no ./drush file; with ./composer: ./composer exec drush -- <command>")
    elif [[ -e "$path/drush" || -L "$path/drush" ]]; then
        LAUNCHER_PLAN_NOTES+=("./drush exists already; kept")
    elif [[ ! -x "$path/vendor/bin/drush" ]]; then
        LAUNCHER_PLAN_NOTES+=("./drush: Drush is not installed in the project (vendor/bin/drush)")
    else
        LAUNCHER_PLAN_WRITE+=(drush)
    fi

    if [[ -e "$path/composer" || -L "$path/composer" ]]; then
        LAUNCHER_PLAN_NOTES+=("./composer exists already; kept")
    elif [[ ! -f "$path/composer.json" ]]; then
        LAUNCHER_PLAN_NOTES+=("./composer: not a Composer project")
    elif ! command -v composer > /dev/null 2>&1; then
        LAUNCHER_PLAN_NOTES+=("./composer: Composer is not installed")
    else
        LAUNCHER_PLAN_WRITE+=(composer)
    fi
}

# Writes the planned launchers. Arguments: machine name, then the values
# of get_launcher_values.
write_planned_launchers() {
    local machine_name="$1"
    local url="$2"
    local site="$3"
    local socket="$4"
    local error_log="$5"
    local path="$RECORD_PROJECT_PATH"
    local php_binary
    local shim_dir="$path/.drupal-local-installer/bin"
    local name
    local drush_uri=""
    local written=()

    if ! php_binary="$(command -v "php${RECORD_PHP_VERSION}")"; then
        echo "[ERROR] PHP $RECORD_PHP_VERSION is not installed."
        return 1
    fi

    # The per-project "php" that the launchers put first in PATH.
    if [[ " ${LAUNCHER_PLAN_WRITE[*]} " == *" drush "* || " ${LAUNCHER_PLAN_WRITE[*]} " == *" composer "* ]] &&
       [[ ! -e "$shim_dir/php" && ! -L "$shim_dir/php" ]]; then
        if ! run_as_project_user "$PROJECT_USER" mkdir -p "$shim_dir" ||
           ! run_as_project_user "$PROJECT_USER" ln -s "$php_binary" "$shim_dir/php"; then
            echo "[ERROR] Could not create the project PHP link in $shim_dir"
            return 1
        fi
    fi

    if [[ "$url" =~ ^https?://[A-Za-z0-9_.:-]+(/[A-Za-z0-9._~/-]*)?$ ]]; then
        drush_uri="export DRUSH_OPTIONS_URI=\"\${DRUSH_OPTIONS_URI:-$url}\""
    fi

    for name in "${LAUNCHER_PLAN_WRITE[@]}"; do
        case "$name" in
            start)
                create_start_script "$path" "$RECORD_PHP_VERSION" "$RECORD_DATABASE_ENGINE" \
                    "$machine_name" "$PROJECT_USER" "$url" "$site" "$socket" "$error_log" > /dev/null || return 1
                ;;
            drush)
                # Literal text: expanded when the launcher runs.
                # shellcheck disable=SC2016
                write_project_launcher "$path/drush" "$php_binary" \
                    '"$project_dir/vendor/bin/drush"' "$PROJECT_USER" "$drush_uri" || return 1
                ;;
            composer)
                write_project_launcher "$path/composer" "$php_binary" \
                    "$php_binary $(command -v composer)" "$PROJECT_USER" || return 1
                ;;
        esac

        written+=("/$name")
        echo "[OK] ./$name written (PHP $RECORD_PHP_VERSION)"
    done

    # For this computer only; the project's .gitignore is not touched.
    if [[ -d "$path/.git" && "${#written[@]}" -gt 0 ]]; then
        run_as_project_user "$PROJECT_USER" mkdir -p "$path/.git/info" &&
        append_missing_lines "$path/.git/info/exclude" "$PROJECT_USER" \
            "# Written by drupal-local-installer for this computer only." \
            "${written[@]}" "/.drupal-local-installer/" &&
        echo "[OK] Added to .git/info/exclude (this computer only; .gitignore unchanged)"
    fi
}

print_launcher_plan() {
    local name
    local note

    for name in "${LAUNCHER_PLAN_WRITE[@]}"; do
        case "$name" in
            start) echo "  Write ./start     starts PHP-FPM $RECORD_PHP_VERSION, Nginx and the database; checks the site" ;;
            drush) echo "  Write ./drush     Drush with PHP $RECORD_PHP_VERSION and the project URL" ;;
            composer) echo "  Write ./composer  Composer with PHP $RECORD_PHP_VERSION" ;;
        esac
    done

    for note in "${LAUNCHER_PLAN_NOTES[@]}"; do
        echo "  Skip  $note"
    done
}

# The launchers of one registered project. $2 = "ask" (--launchers) or
# "yes" (already chosen, e.g. from the --scan list).
create_launchers_for_project() {
    local machine_name="$1"
    local mode="${2:-ask}"
    local record
    local values
    local url
    local site
    local socket
    local error_log
    local answer

    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        echo "[ERROR] '$machine_name' is not in the registry."
        suggest_registered_name "$machine_name"
        return 1
    fi

    acquire_project_lock "$machine_name" || return 1
    load_project_record "$machine_name" "$record" || return 1

    if [[ ! -d "$RECORD_PROJECT_PATH" ]]; then
        print_missing_project_folder "$machine_name"
        return 1
    fi

    if [[ "$(stat -c '%U' "$RECORD_PROJECT_PATH")" != "$PROJECT_USER" ]]; then
        echo "[BLOCKED] $RECORD_PROJECT_PATH belongs to $(stat -c '%U' "$RECORD_PROJECT_PATH"), not to you ($PROJECT_USER)."
        return 1
    fi

    if [[ ! "$RECORD_PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || ! command -v "php${RECORD_PHP_VERSION}" > /dev/null; then
        echo "[BLOCKED] The project's PHP (${RECORD_PHP_VERSION:-unknown}) is not available."
        return 1
    fi

    values="$(get_launcher_values "$record" "$machine_name")"
    IFS='|' read -r url site socket error_log <<< "$values"
    plan_launchers "$url"

    echo
    echo "Launchers for $machine_name ($RECORD_PROJECT_PATH):"
    print_launcher_plan

    if [[ "${#LAUNCHER_PLAN_WRITE[@]}" -eq 0 ]]; then
        echo "[OK] Nothing to write."
        return 0
    fi

    echo "  Only these files change (an existing file is never replaced); Nginx, the"
    echo "  PHP-FPM pool and the project's settings stay as they are."

    if [[ "$mode" == "ask" ]]; then
        if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
            echo
            echo "[DRY RUN] Nothing was changed."
            return 0
        fi

        if ! read -r -p "Write them? [y/N]: " answer || [[ ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Nothing was changed."
            return 1
        fi
    fi

    write_planned_launchers "$machine_name" "$url" "$site" "$socket" "$error_log"
}

run_launchers_project() {
    create_launchers_for_project "$(get_project_machine_name "$1")" ask
}

# After --scan: launchers for the projects just registered, chosen from
# a list (the choice is the consent).
offer_launchers_after_scan() {
    local -a names=("$@")
    local -a labels=()
    local name
    local index

    [[ "${#names[@]}" -gt 0 ]] || return 0

    for name in "${names[@]}"; do
        labels+=("$name")
    done

    echo
    echo "Adopted projects have no ./start, ./drush and ./composer: Drush and Composer"
    echo "then run with the system's default PHP, which may not be the project's."
    echo "The launchers are small files in the project folder; nothing else changes."

    choose_from_checklist "Write the launchers for which projects?" "${labels[@]}" || { echo "  No launchers written."; return 0; }

    for index in "${CHECKLIST_SELECTED[@]}"; do
        create_launchers_for_project "${names[index]}" yes || echo "  [FAILED] Launchers for ${names[index]}"
    done
}
