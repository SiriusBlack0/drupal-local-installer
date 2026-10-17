#!/usr/bin/env bash

# ==================================================
# Finding existing projects (./install.sh --scan)
#
# Looks for Drupal projects in the projects directory that are not in
# the registry and registers them, one by one, only when the user says
# so. Detection only reads files; nothing on the system is changed.
# Registered this way, a project is "adopted": the installer never
# changes its configuration, and removing it never touches shared
# resources (a shared PHP-FPM pool, the database user).
# ==================================================

get_nginx_sites_enabled_dir() {
    printf '%s\n' "${NGINX_SITES_ENABLED_DIR:-/etc/nginx/sites-enabled}"
}

get_nginx_sites_available_dir() {
    printf '%s\n' "${NGINX_SITES_AVAILABLE_DIR:-/etc/nginx/sites-available}"
}

get_php_etc_dir() {
    printf '%s\n' "${PHP_ETC_DIR:-/etc/php}"
}

# Drupal version of a web root (Drupal 8+ or Drupal 7), empty if none.
get_drupal_version_in() {
    local web_root="$1"

    if [[ -f "$web_root/core/lib/Drupal.php" ]]; then
        sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" "$web_root/core/lib/Drupal.php" | head -n 1
    elif [[ -f "$web_root/includes/bootstrap.inc" ]]; then
        sed -nE "s/.*define\('VERSION', '([^']+)'\).*/\1/p" "$web_root/includes/bootstrap.inc" | head -n 1
    else
        return 1
    fi
}

find_web_root() {
    local project_dir="$1"
    local sub
    local candidate

    for sub in web docroot html public ""; do
        candidate="${project_dir}${sub:+/$sub}"

        if [[ -n "$(get_drupal_version_in "$candidate" 2>/dev/null)" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# Enabled Nginx site whose "root" is the web root.
find_nginx_site_for_root() {
    local web_root="${1%/}"
    local file
    local root

    for file in "$(get_nginx_sites_enabled_dir)"/*; do
        [[ -f "$file" ]] || continue

        while read -r root; do
            if [[ "${root%/}" == "$web_root" ]]; then
                printf '%s\n' "$file"
                return 0
            fi
        done < <(sed -nE 's/^[[:space:]]*root[[:space:]]+"?([^";]+)"?[[:space:]]*;.*/\1/p' "$file")
    done

    return 1
}

get_nginx_directive() {
    local file="$1"
    local directive="$2"

    sed -nE "s/^[[:space:]]*${directive}[[:space:]]+([^;]+);.*/\1/p" "$file" | head -n 1
}

# A PHP-FPM pool file that serves only this socket and only this site.
# Shared pools (www.conf, the default socket) are never recorded, so
# --remove can never delete them.
find_exclusive_pool() {
    local socket="$1"
    local php_version="$2"
    local pool
    local users

    [[ "$socket" != "/run/php/php${php_version}-fpm.sock" ]] || return 1

    users="$(grep -lF "$socket" "$(get_nginx_sites_enabled_dir)"/* 2>/dev/null | wc -l)"
    [[ "$users" -eq 1 ]] || return 1

    for pool in "$(get_php_etc_dir)/$php_version/fpm/pool.d/"*.conf; do
        [[ -f "$pool" && "$(basename "$pool")" != "www.conf" ]] || continue

        if grep -qE "^[[:space:]]*listen[[:space:]]*=[[:space:]]*${socket//./\\.}[[:space:]]*$" "$pool"; then
            printf '%s\n' "$pool"
            return 0
        fi
    done

    return 1
}

# Database details through the project's own Drush (Drupal 8+), run
# with the project's PHP. Prints "driver|name|user"; no password.
detect_database_with_drush() {
    local project_dir="$1"
    local php_version="$2"
    local drush="$project_dir/vendor/bin/drush"
    local php_binary
    local shim
    local json

    [[ -x "$drush" ]] || return 1
    php_binary="$(command -v "php${php_version}")" || return 1

    shim="$(mktemp -d)"
    ln -s "$php_binary" "$shim/php"

    json="$(cd "$project_dir" && PATH="$shim:$PATH" timeout 60 "$drush" status \
        --fields=db-driver,db-name,db-username --format=json 2>/dev/null)" || json=""
    rm -rf "$shim"

    [[ -n "$json" ]] || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "$php_binary" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d) || empty($d["db-driver"])) { exit(1); }
echo $d["db-driver"], "|", $d["db-name"] ?? "", "|", $d["db-username"] ?? "", "\n";
'
}

# Support level of an existing project for the installer.
get_project_support() {
    local drupal_version="$1"
    local php_version="$2"
    local major="${drupal_version%%.*}"
    local minor
    local oldest

    minor="$(echo "$drupal_version" | cut -d. -f1,2)"

    if [[ "$major" =~ ^[0-9]+$ ]] && (( major <= 9 )); then
        echo "unsupported (Drupal $major is end of life)"
    elif ! get_compatibility_row "$minor" > /dev/null; then
        oldest="$(get_compatibility_rows | grep -m 1 "^${major}\." | cut -d'|' -f1)"

        if [[ -n "$oldest" ]] && ! version_at_least "$minor" "$oldest"; then
            echo "unsupported (Drupal $minor is end of life)"
        else
            echo "unsupported (Drupal $minor is not in the compatibility table yet)"
        fi
    elif [[ -z "$php_version" ]]; then
        echo "supported (PHP version unknown)"
    elif ! command -v "php${php_version}" > /dev/null; then
        echo "php_missing (PHP $php_version is not installed)"
    else
        echo "supported"
    fi
}

is_path_registered() {
    local project_path="$1"
    local record

    for record in "$(get_registry_directory)"/*.conf; do
        [[ -f "$record" ]] || continue

        if [[ "$(read_project_field "$record" project_path)" == "$project_path" ]]; then
            return 0
        fi
    done

    return 1
}

# Fills REGISTRY_VALUES for one project directory. Returns 1 when the
# directory is not a Drupal project.
detect_project() {
    local project_dir="$1"
    local web_root
    local version
    local site=""
    local available=""
    local socket=""
    local php_version=""
    local pool=""
    local server_name=""
    local db=""
    local driver=""
    local db_name=""
    local db_user=""
    local engine="unknown"
    local sqlite_path=""

    web_root="$(find_web_root "$project_dir")" || return 1
    version="$(get_drupal_version_in "$web_root")"

    if site="$(find_nginx_site_for_root "$web_root")"; then
        server_name="$(get_nginx_directive "$site" server_name | awk '{print $1}')"
        socket="$(get_nginx_directive "$site" fastcgi_pass)"
        socket="${socket#unix:}"

        if [[ "$socket" =~ php([0-9]+\.[0-9]+)-fpm ]]; then
            php_version="${BASH_REMATCH[1]}"
            pool="$(find_exclusive_pool "$socket" "$php_version")" || pool=""
        fi

        available="$(readlink -f "$site")"

        if [[ "$available" != "$(get_nginx_sites_available_dir)/"* ]]; then
            available=""
        fi
    else
        site=""
    fi

    if [[ -n "$php_version" ]] && db="$(detect_database_with_drush "$project_dir" "$php_version")"; then
        IFS='|' read -r driver db_name db_user <<< "$db"

        case "$driver" in
            mysql)
                if is_database_engine_installed mariadb; then engine="mariadb"; else engine="mysql"; fi
                ;;
            pgsql) engine="postgresql" ;;
            sqlite)
                engine="sqlite"
                sqlite_path="$db_name"
                [[ "$sqlite_path" == /* ]] || sqlite_path="$web_root/$sqlite_path"
                db_name=""
                db_user=""
                ;;
        esac
    fi

    declare -gA REGISTRY_VALUES
    REGISTRY_VALUES=(
        [managed_by]="adopted"
        [support]="$(get_project_support "$version" "$php_version")"
        [name]="$(basename "$project_dir")"
        [machine_name]="$(get_project_machine_name "$(basename "$project_dir")")"
        [owner]="$(stat -c '%U' "$project_dir")"
        [project_path]="$project_dir"
        [web_root]="$web_root"
        [url]="${server_name:+http://$server_name}"
        [drupal_version]="$version"
        [install_profile]=""
        [php_version]="$php_version"
        [database_engine]="$engine"
        [database_name]="$db_name"
        [database_user]="$db_user"
        [sqlite_path]="$sqlite_path"
        [php_fpm_pool]="$pool"
        [php_fpm_socket]="$socket"
        [nginx_available]="$available"
        [nginx_enabled]="$site"
        [log_file]=""
    )
}

print_detected_project() {
    echo
    echo "  ${REGISTRY_VALUES[name]}  ($(dirname "${REGISTRY_VALUES[project_path]}")/${REGISTRY_VALUES[name]})"
    echo "    Drupal:   ${REGISTRY_VALUES[drupal_version]}  [${REGISTRY_VALUES[support]}]"
    echo "    URL:      ${REGISTRY_VALUES[url]:-no Nginx site found}"
    echo "    PHP:      ${REGISTRY_VALUES[php_version]:-unknown}  (pool: ${REGISTRY_VALUES[php_fpm_pool]:-shared, never removed})"

    case "${REGISTRY_VALUES[database_engine]}" in
        unknown) echo "    Database: unknown (no Drush, or Drush could not read it)" ;;
        sqlite) echo "    Database: sqlite ${REGISTRY_VALUES[sqlite_path]}" ;;
        *) echo "    Database: ${REGISTRY_VALUES[database_engine]} '${REGISTRY_VALUES[database_name]}' (user '${REGISTRY_VALUES[database_user]}')" ;;
    esac
}

run_scan_projects() {
    local base_dir
    local project_dir
    local answer
    local found=0
    local registered=0
    local record

    base_dir="$(get_projects_base_dir)" || return 1

    echo
    echo "Looking for Drupal projects in $base_dir that are not registered..."
    echo "(Only reading: nothing is changed unless you answer y.)"

    for project_dir in "$base_dir"/*; do
        [[ -d "$project_dir" && ! -L "$project_dir" ]] || continue
        is_path_registered "$project_dir" && continue

        REGISTRY_VALUES=()
        detect_project "$project_dir" || continue
        found=$((found + 1))

        print_detected_project

        PROJECT_MACHINE_NAME="${REGISTRY_VALUES[machine_name]}"
        record="$(get_project_record_path "$PROJECT_MACHINE_NAME")" || continue

        if [[ -e "$record" ]]; then
            echo "    [SKIPPED] The name '$PROJECT_MACHINE_NAME' is already used in the registry."
            continue
        fi

        if ! read -r -p "    Register it? [y/N]: " answer; then
            echo
            break
        fi

        case "$answer" in
            y|Y)
                if write_project_record > /dev/null; then
                    echo "    [OK] Registered as '$PROJECT_MACHINE_NAME' (adopted)"
                    registered=$((registered + 1))
                fi
                ;;
            *) echo "    Not registered." ;;
        esac
    done

    REGISTRY_VALUES=()

    echo
    if [[ "$found" -eq 0 ]]; then
        echo "No unregistered Drupal projects found."
    else
        echo "Found $found unregistered project(s), registered $registered."
        echo "Adopted projects are listed with ./install.sh --list. The installer"
        echo "never changes their configuration."
    fi
}
