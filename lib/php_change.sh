#!/usr/bin/env bash

# ==================================================
# Changing the PHP version of a project (--php NAME VERSION)
#
# The new PHP-FPM pool is started next to the old one, then Nginx is
# switched to it. Only when the site answers with the new PHP is the
# old pool removed. Code and database are never changed.
#
# Adopted projects (--scan) are changed only after an explicit
# confirmation: their Nginx site gets the new socket, nothing else in
# their configuration changes, and their old pool is never removed.
# ==================================================

PHP_CHANGE_OLD=""
PHP_CHANGE_NEW=""
PHP_CHANGE_SITE_FILE=""
PHP_CHANGE_OLD_PASS=""
PHP_CHANGE_NEW_SOCKET=""
PHP_CHANGE_NEW_POOL=""
PHP_CHANGE_OLD_POOL=""
PHP_CHANGE_BACKUP_DIR=""
PHP_CHANGE_HAS_LAUNCHERS=0
PHP_CHANGE_HAS_START=0
PHP_CHANGE_POOL_ADDED=0
PHP_CHANGE_SITE_SWITCHED=0
PHP_CHANGE_LAUNCHERS_CHANGED=0
PHP_CHANGE_MISSING_PACKAGES=()

# First line of the pools this feature creates for adopted projects: such
# a pool belongs to the installer and is removed again by a later change.
PHP_CHANGE_POOL_MARKER="; Created by drupal-local-installer (--php)"

# Package suffixes of the old PHP that are not copied to the new one.
PHP_CHANGE_SKIP_SUFFIXES="dev dbgsym phpdbg cgi"

# A literal value escaped for grep -E and sed -E (sed uses "|" as its
# delimiter here, so "/" needs no escaping).
escape_sed_regex() {
    printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'
}

count_fastcgi_pass() {
    local file="$1"
    local value="$2"

    grep -cE "^[^#]*fastcgi_pass[[:space:]]+$(escape_sed_regex "$value")[[:space:]]*;" "$file" || true
}

# Writes a file owned by root through stdin (keeps owner and mode of an
# existing file).
write_root_file() {
    sudo tee -- "$1" > /dev/null
}

# A value from a PHP-FPM pool file, e.g. "user".
get_pool_value() {
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p" "$1" | head -n 1
}

# ---------------------------------------------------
# Packages
# ---------------------------------------------------

# Plans the packages of the new PHP: FPM, CLI, the extensions Drupal
# needs, and the same extension packages the old PHP has (php8.3-redis
# -> php8.4-redis). Packages that do not exist for the new PHP are
# listed in PHP_CHANGE_MISSING_PACKAGES.
plan_php_change_packages() {
    local old="$1"
    local new="$2"
    local engine="$3"
    local package
    local suffix
    local candidate

    INSTALL_PACKAGES=()
    PHP_CHANGE_MISSING_PACKAGES=()

    is_php_fpm_installed "$new" || add_install_package "php${new}-fpm"
    is_php_cli_installed "$new" || add_install_package "php${new}-cli"

    PHP_VERSION="$new" DATABASE_ENGINE="$engine" plan_php_extensions > /dev/null

    while read -r package; do
        suffix="${package#php"${old}"-}"
        [[ " $PHP_CHANGE_SKIP_SUFFIXES " == *" $suffix "* ]] && continue

        candidate="php${new}-${suffix}"

        if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null | grep -qx "install ok installed"; then
            continue
        fi

        if is_apt_package_available "$candidate"; then
            add_install_package "$candidate"
        else
            PHP_CHANGE_MISSING_PACKAGES+=("$candidate")
        fi
    done < <(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' "php${old}-*" 2>/dev/null |
        awk '$2 == "ii" { sub(/:.*/, "", $1); print $1 }' | sort -u)
}

# ---------------------------------------------------
# Composer: do the installed packages accept the new PHP?
# ---------------------------------------------------

# Prints the failed requirements, one per line; returns 1 if any.
check_platform_requirements() {
    local project_path="$1"
    local new="$2"
    local json

    json="$(run_project_composer "$project_path" "$new" \
        check-platform-reqs --format=json 2>/dev/null)" || true

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${new}" -r '
$rows = json_decode(stream_get_contents(STDIN), true);
if (!is_array($rows)) { echo "Composer did not answer (check-platform-reqs)\n"; exit(2); }
$bad = 0;
foreach ($rows as $r) {
    if (($r["status"] ?? "") === "success") { continue; }
    $bad = 1;
    $f = $r["failed_requirement"] ?? null;
    echo $r["name"], " ", $r["version"], ": ", $r["status"],
        $f ? " (" . $f["source"] . " requires " . $f["target"] . " " . $f["constraint"] . ")" : "", "\n";
}
exit($bad);
'
}

# config.platform.php in composer.json makes Composer resolve packages
# for that PHP version, whatever PHP runs.
get_composer_platform_php() {
    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    "php${2}" -r '
$c = json_decode(file_get_contents($argv[1]), true);
echo $c["config"]["platform"]["php"] ?? "";
' "$1/composer.json" 2>/dev/null
}

# ---------------------------------------------------
# PHP-FPM pool, Nginx site, launchers
# ---------------------------------------------------

# Pool for an adopted project: same user and group as its old pool, the
# PHP settings of the old pool (php_value, php_admin_value, env) copied.
generate_adopted_pool_config() {
    local machine_name="$1"
    local new="$2"
    local old_pool="$3"
    local pool_user="$PROJECT_USER"
    local pool_group="www-data"
    local value

    if [[ -n "$old_pool" && -f "$old_pool" ]]; then
        value="$(get_pool_value "$old_pool" user)"
        [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] && pool_user="$value"
        value="$(get_pool_value "$old_pool" group)"
        [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] && pool_group="$value"
    fi

    echo "$PHP_CHANGE_POOL_MARKER"
    generate_php_fpm_pool_config "$machine_name" "$new" "$pool_user" |
        sed "s/^group = www-data$/group = $pool_group/" || return 1

    if [[ -n "$old_pool" && -f "$old_pool" ]]; then
        echo
        echo "; Settings copied from $old_pool"
        grep -E '^[[:space:]]*(php_value|php_admin_value|php_flag|php_admin_flag|env)\[' "$old_pool" || true
    fi
}

install_new_pool() {
    local machine_name="$1"
    local new="$2"
    local temp_file

    if [[ "$RECORD_MANAGED_BY" != "adopted" ]]; then
        install_php_fpm_pool "$machine_name" "$new" "$PROJECT_USER" || return 1
        PHP_CHANGE_POOL_ADDED=1
        return 0
    fi

    temp_file="$(mktemp)"

    if ! generate_adopted_pool_config "$machine_name" "$new" "$PHP_CHANGE_OLD_POOL" > "$temp_file" ||
       ! sudo install -m 0644 -o root -g root "$temp_file" "$PHP_CHANGE_NEW_POOL"; then
        rm -f "$temp_file"
        echo "[ERROR] Could not install the PHP-FPM pool."
        return 1
    fi

    rm -f "$temp_file"
    PHP_CHANGE_POOL_ADDED=1

    if ! run_logged "Checking PHP-FPM configuration" sudo "php-fpm${new}" -t ||
       ! run_logged "Reloading PHP-FPM ${new}" reload_or_start_service "php${new}-fpm"; then
        return 1
    fi

    echo "[OK] PHP-FPM pool ready: $PHP_CHANGE_NEW_SOCKET"
}

wait_for_socket() {
    local socket="$1"
    local attempt

    for attempt in 1 2 3 4 5; do
        [[ -S "$socket" ]] && return 0
        [[ "$attempt" -lt 5 ]] && sleep 1
    done

    echo "[ERROR] The new PHP-FPM socket did not appear: $socket"
    return 1
}

switch_nginx_site() {
    local old_regex

    old_regex="$(escape_sed_regex "$PHP_CHANGE_OLD_PASS")"

    if ! sudo sed -i -E "s|^([^#]*fastcgi_pass[[:space:]]+)${old_regex}([[:space:]]*;)|\1unix:${PHP_CHANGE_NEW_SOCKET}\2|" "$PHP_CHANGE_SITE_FILE"; then
        echo "[ERROR] Could not change $PHP_CHANGE_SITE_FILE"
        return 1
    fi

    PHP_CHANGE_SITE_SWITCHED=1

    if ! run_logged "Checking Nginx configuration" sudo nginx -t ||
       ! run_logged "Reloading Nginx" reload_or_start_service nginx; then
        return 1
    fi

    echo "[OK] Nginx site uses the new socket: $PHP_CHANGE_NEW_SOCKET"
}

is_generated_file() {
    [[ -f "$1" && ! -L "$1" ]] && grep -q '^# Generated by drupal-local-installer' "$1"
}

backup_launchers() {
    local name

    for name in drush composer start; do
        if is_generated_file "$RECORD_PROJECT_PATH/$name"; then
            run_as_project_user "$PROJECT_USER" cp -p -- "$RECORD_PROJECT_PATH/$name" "$PHP_CHANGE_BACKUP_DIR/$name" || return 1
        fi
    done

    if [[ -L "$RECORD_PROJECT_PATH/.drupal-local-installer/bin/php" ]]; then
        run_as_project_user "$PROJECT_USER" cp -P -- "$RECORD_PROJECT_PATH/.drupal-local-installer/bin/php" "$PHP_CHANGE_BACKUP_DIR/php-link" || return 1
    fi
}

rewrite_launchers() {
    local new="$1"
    local path="$RECORD_PROJECT_PATH"

    PHP_CHANGE_LAUNCHERS_CHANGED=1

    run_as_project_user "$PROJECT_USER" rm -f -- "$path/drush" "$path/composer" "$path/.drupal-local-installer/bin/php" || return 1
    create_project_launchers "$path" "$new" "$PROJECT_USER" || return 1

    if [[ "$PHP_CHANGE_HAS_START" -eq 1 ]]; then
        run_as_project_user "$PROJECT_USER" rm -f -- "$path/start" &&
        create_start_script "$path" "$new" "$RECORD_DATABASE_ENGINE" "$(basename "$path")" "$PROJECT_USER" || return 1
    fi
}

restore_launchers() {
    local name
    local path="$RECORD_PROJECT_PATH"

    for name in drush composer start; do
        if [[ -f "$PHP_CHANGE_BACKUP_DIR/$name" ]]; then
            run_as_project_user "$PROJECT_USER" rm -f -- "$path/$name" &&
            run_as_project_user "$PROJECT_USER" cp -p -- "$PHP_CHANGE_BACKUP_DIR/$name" "$path/$name" || return 1
        fi
    done

    if [[ -L "$PHP_CHANGE_BACKUP_DIR/php-link" ]]; then
        run_as_project_user "$PROJECT_USER" rm -f -- "$path/.drupal-local-installer/bin/php" &&
        run_as_project_user "$PROJECT_USER" cp -P -- "$PHP_CHANGE_BACKUP_DIR/php-link" "$path/.drupal-local-installer/bin/php" || return 1
    fi
}

# Ctrl+C (or kill) while the project is being changed: undo, then stop.
interrupt_php_change() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the PHP change and restoring the project..."
    rollback_php_change
    exit 130
}

# A pool of an adopted project that the installer itself created earlier
# (first line PHP_CHANGE_POOL_MARKER) and that the registry records.
is_installer_created_pool() {
    [[ -n "$1" && -f "$1" && "$1" == "$RECORD_POOL" ]] &&
        [[ "$(head -n 1 "$1")" == "$PHP_CHANGE_POOL_MARKER" ]]
}

# Undoes the steps that were done, newest first. Packages stay.
rollback_php_change() {
    local failed=0

    echo
    echo "Restoring the previous PHP $PHP_CHANGE_OLD setup..."

    if [[ "$PHP_CHANGE_LAUNCHERS_CHANGED" -eq 1 ]]; then
        if restore_launchers; then
            echo "[OK] Launchers restored (PHP $PHP_CHANGE_OLD)"
        else
            echo "[FAILED] Launchers: copies are in $PHP_CHANGE_BACKUP_DIR"
            failed=1
        fi
    fi

    if [[ "$PHP_CHANGE_SITE_SWITCHED" -eq 1 ]]; then
        if write_root_file "$PHP_CHANGE_SITE_FILE" < "$PHP_CHANGE_BACKUP_DIR/nginx-site.conf" &&
           sudo nginx -t > /dev/null 2>&1 && reload_or_start_service nginx > /dev/null 2>&1; then
            echo "[OK] Nginx site restored"
        else
            echo "[FAILED] Nginx site: the original is $PHP_CHANGE_BACKUP_DIR/nginx-site.conf"
            failed=1
        fi
    fi

    if [[ "$PHP_CHANGE_POOL_ADDED" -eq 1 ]]; then
        if sudo rm -f -- "$PHP_CHANGE_NEW_POOL" &&
           reload_or_start_service "php${PHP_CHANGE_NEW}-fpm" > /dev/null 2>&1; then
            echo "[OK] New PHP-FPM pool removed"
        else
            echo "[FAILED] Remove by hand: sudo rm $PHP_CHANGE_NEW_POOL && sudo systemctl reload php${PHP_CHANGE_NEW}-fpm"
            failed=1
        fi
    fi

    if [[ "$failed" -eq 0 ]]; then
        echo "[OK] The project runs with PHP $PHP_CHANGE_OLD again; nothing else was changed."
        return 0
    fi

    return 1
}

# Removes the old pool of an installer project. A PHP-FPM without any
# pool cannot run, so the last pool of a version is kept.
remove_old_pool() {
    local old_dir
    local remaining

    old_dir="$(dirname "$PHP_CHANGE_OLD_POOL")"
    remaining="$(find "$old_dir" -maxdepth 1 -name '*.conf' ! -path "$PHP_CHANGE_OLD_POOL" 2>/dev/null | wc -l)"

    if [[ "$remaining" -eq 0 ]]; then
        echo "[INFO] Kept $PHP_CHANGE_OLD_POOL: it is the only pool of PHP $PHP_CHANGE_OLD."
        return 0
    fi

    if sudo rm -f -- "$PHP_CHANGE_OLD_POOL" &&
       sudo "php-fpm${PHP_CHANGE_OLD}" -t > /dev/null 2>&1 &&
       reload_or_start_service "php${PHP_CHANGE_OLD}-fpm" > /dev/null 2>&1; then
        echo "[OK] Old PHP-FPM pool removed: $PHP_CHANGE_OLD_POOL"
    else
        echo "[WARNING] The old pool could not be removed cleanly: $PHP_CHANGE_OLD_POOL"
        echo "          Check with: sudo php-fpm${PHP_CHANGE_OLD} -t"
    fi
}

verify_php_change() {
    local headers

    if [[ "$(run_project_drush "$RECORD_PROJECT_PATH" "$PHP_CHANGE_NEW" status --field=bootstrap 2>/dev/null)" != *"Successful"* ]]; then
        echo "[ERROR] Drush cannot bootstrap the site with PHP $PHP_CHANGE_NEW."
        return 1
    fi

    if [[ -n "$RECORD_URL" ]] && command -v curl > /dev/null; then
        headers="$(get_site_headers 4 "$RECORD_URL")"

        if ! grep -qi '^x-generator: drupal' <<< "$headers"; then
            echo "[ERROR] $RECORD_URL does not answer as a Drupal site with PHP $PHP_CHANGE_NEW: $(describe_site_answer "$headers")"
            return 1
        fi
    fi

    echo "[OK] The site runs with PHP $PHP_CHANGE_NEW"
}

# PHP settings in the FPM php.ini that differ between the versions.
report_php_setting_differences() {
    local old="$1"
    local new="$2"
    local etc
    local key
    local old_value
    local new_value
    local found=0

    etc="$(get_php_etc_dir)"
    [[ -f "$etc/$old/fpm/php.ini" && -f "$etc/$new/fpm/php.ini" ]] || return 0

    for key in memory_limit max_execution_time upload_max_filesize post_max_size max_input_vars; do
        old_value="$("php${old}" -n -c "$etc/$old/fpm/php.ini" -r "echo ini_get('$key');" 2>/dev/null)" || continue
        new_value="$("php${new}" -n -c "$etc/$new/fpm/php.ini" -r "echo ini_get('$key');" 2>/dev/null)" || continue

        if [[ "$old_value" != "$new_value" ]]; then
            if [[ "$found" -eq 0 ]]; then
                echo "[INFO] Settings in $etc/$new/fpm/php.ini that differ from PHP $old:"
                found=1
            fi
            echo "         $key: $old_value (PHP $old) -> $new_value (PHP $new)"
        fi
    done
}

confirm_php_change() {
    local machine_name="$1"
    local answer

    echo
    echo "Type the project name to change its PHP version."

    if ! read -r -p "Project name ($machine_name): " answer; then
        echo
        return 1
    fi

    [[ "$answer" == "$machine_name" ]]
}

# ---------------------------------------------------
# --php NAME VERSION
# ---------------------------------------------------

run_change_php() {
    local name="$1"
    local new="$2"
    local machine_name
    local record
    local web_root
    local current
    local minor
    local status
    local count
    local nginx_dir
    local failures=""
    local platform_checked=0
    local platform_php
    local package_count
    local old_php_problem=""

    machine_name="$(get_project_machine_name "$name")"

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project name: '$name'"
        return 1
    fi

    if [[ ! "$new" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Invalid PHP version: '$new' (for example: 8.4)"
        return 1
    fi

    record="$(get_project_record_path "$machine_name")" || return 1

    if [[ ! -f "$record" ]]; then
        echo "[ERROR] '$machine_name' is not in the registry. Register it with --scan first."
        suggest_registered_name "$machine_name"
        return 1
    fi

    acquire_project_lock "$machine_name" || return 1
    load_project_record "$machine_name" "$record" || return 1

    PHP_CHANGE_OLD="$RECORD_PHP_VERSION"
    PHP_CHANGE_NEW="$new"
    PHP_CHANGE_POOL_ADDED=0
    PHP_CHANGE_SITE_SWITCHED=0
    PHP_CHANGE_LAUNCHERS_CHANGED=0
    web_root="${RECORD_WEB_ROOT:-$RECORD_PROJECT_PATH/web}"

    # ---- Checks (read only) ----
    if [[ ! "$PHP_CHANGE_OLD" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "[BLOCKED] The project's current PHP version is unknown."
        return 1
    fi

    if [[ "$PHP_CHANGE_OLD" == "$new" ]]; then
        echo "[OK] $machine_name already uses PHP $new."
        return 0
    fi

    if [[ ! -d "$RECORD_PROJECT_PATH" ]]; then
        echo "[ERROR] Project folder not found: $RECORD_PROJECT_PATH"
        return 1
    fi

    if [[ "$(stat -c '%U' "$RECORD_PROJECT_PATH")" != "$PROJECT_USER" ]]; then
        echo "[BLOCKED] $RECORD_PROJECT_PATH belongs to $(stat -c '%U' "$RECORD_PROJECT_PATH"), not to you ($PROJECT_USER)."
        return 1
    fi

    if ! current="$(get_drupal_version_in "$web_root")" || [[ ! "$current" =~ ^[0-9]+\.[0-9]+ ]]; then
        echo "[ERROR] Could not read the Drupal version in $web_root"
        return 1
    fi

    minor="$(echo "$current" | cut -d. -f1,2)"

    if ! get_supported_php_versions "$minor" > /dev/null; then
        echo "[BLOCKED] Drupal $current is not in config/compatibility.conf; its PHP support is unknown."
        return 1
    fi

    if ! get_supported_php_versions "$minor" | grep -qxF "$new"; then
        echo "[BLOCKED] Drupal $minor does not support PHP $new."
        echo "          Supported: $(get_supported_php_versions "$minor" | paste -sd ' ' -)"
        return 1
    fi

    if [[ ! -f "$RECORD_PROJECT_PATH/composer.json" || ! -f "$RECORD_PROJECT_PATH/composer.lock" ]]; then
        echo "[BLOCKED] Not a Composer project (composer.json and composer.lock are needed)."
        return 1
    fi

    # The Nginx site whose fastcgi_pass is changed.
    PHP_CHANGE_SITE_FILE=""
    [[ -n "$RECORD_NGINX_ENABLED" ]] && PHP_CHANGE_SITE_FILE="$(readlink -f "$RECORD_NGINX_ENABLED" 2>/dev/null)"
    nginx_dir="$(dirname "$PHP_CHANGE_SITE_FILE")"

    if [[ -z "$PHP_CHANGE_SITE_FILE" || ! -f "$PHP_CHANGE_SITE_FILE" ]] ||
       [[ "$nginx_dir" != "$(get_nginx_sites_available_dir)" && "$nginx_dir" != "$(get_nginx_sites_enabled_dir)" ]]; then
        echo "[BLOCKED] The project's Nginx site was not found (${RECORD_NGINX_ENABLED:-not recorded})."
        return 1
    fi

    PHP_CHANGE_OLD_PASS="$(get_nginx_directive "$PHP_CHANGE_SITE_FILE" fastcgi_pass)"
    PHP_CHANGE_NEW_SOCKET="$(get_project_php_fpm_socket "$machine_name" "$new")"
    PHP_CHANGE_NEW_POOL="$(get_php_fpm_pool_config_path "$machine_name" "$new")"

    if [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        PHP_CHANGE_OLD_POOL="$(find_pool_for_listen "${PHP_CHANGE_OLD_PASS#unix:}")" || PHP_CHANGE_OLD_POOL=""
    else
        PHP_CHANGE_OLD_POOL="$RECORD_POOL"

        if [[ "$PHP_CHANGE_OLD_PASS" != "unix:$(get_project_php_fpm_socket "$machine_name" "$PHP_CHANGE_OLD")" ]]; then
            echo "[BLOCKED] The Nginx site does not use the project's PHP $PHP_CHANGE_OLD socket"
            echo "          (fastcgi_pass ${PHP_CHANGE_OLD_PASS:-not found}). Was it changed by hand?"
            return 1
        fi
    fi

    count="$(count_fastcgi_pass "$PHP_CHANGE_SITE_FILE" "$PHP_CHANGE_OLD_PASS")"

    if [[ -z "$PHP_CHANGE_OLD_PASS" || "$count" -eq 0 ]]; then
        echo "[BLOCKED] No fastcgi_pass line in $PHP_CHANGE_SITE_FILE"
        echo "          (it may come from an included file). Change it by hand."
        return 1
    fi

    if [[ -e "$PHP_CHANGE_NEW_POOL" || -L "$PHP_CHANGE_NEW_POOL" ]]; then
        echo "[BLOCKED] A PHP-FPM pool already exists: $PHP_CHANGE_NEW_POOL"
        echo "          (for an adopted project often its own original pool for PHP $new;"
        echo "          point its Nginx site back to that pool by hand)."
        return 1
    fi

    if [[ ! -x "$RECORD_PROJECT_PATH/vendor/bin/drush" ]]; then
        echo "[BLOCKED] Drush is not installed in the project (vendor/bin/drush): the change"
        echo "          could not be checked. Add it first: composer require drush/drush"
        return 1
    fi

    if [[ "$(run_project_drush "$RECORD_PROJECT_PATH" "$PHP_CHANGE_OLD" status --field=bootstrap 2>/dev/null)" != *"Successful"* ]]; then
        # A site that is broken BECAUSE of its PHP is exactly what this
        # change fixes; any other broken site is not touched.
        if ! get_supported_php_versions "$minor" | grep -qxF "$PHP_CHANGE_OLD"; then
            old_php_problem="Drupal $minor does not support PHP $PHP_CHANGE_OLD"
        elif ! is_php_cli_installed "$PHP_CHANGE_OLD" || ! is_php_fpm_installed "$PHP_CHANGE_OLD"; then
            old_php_problem="PHP $PHP_CHANGE_OLD is not installed"
        else
            echo "[BLOCKED] The site does not work right now (Drush cannot bootstrap it with PHP $PHP_CHANGE_OLD)."
            echo "          Fix that first: the change could not be checked afterwards."
            return 1
        fi

        echo "[WARNING] The site does not work with PHP $PHP_CHANGE_OLD now: $old_php_problem."
        echo "          Changing to PHP $new is the fix. Afterwards the site must work"
        echo "          with PHP $new; otherwise everything is restored as it is now."
    fi

    # ---- The new PHP: installed, or available from a package source ----
    status="$(get_php_version_status "$new")"

    if [[ "$status" == "not_available" ]]; then
        echo "[NOT AVAILABLE] PHP $new is not installed and not in this system's package sources."

        case "$(get_php_source_status)" in
            ppa)
                echo "  The system uses the old ondrej/php PPA. Switch to its replacement first:"
                echo "  ./install.sh --php-source"
                return 1
                ;;
            sury)
                echo "  $SURY_PHP_URL has no PHP $new for this Ubuntu release."
                return 1
                ;;
        esac

        if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
            echo "  Other PHP versions come from $SURY_PHP_URL: ./install.sh --php-source"
            return 1
        fi

        echo
        require_sudo || return 1
        add_sury_php_source || return 1

        if [[ "$(get_php_version_status "$new")" == "not_available" ]]; then
            echo "[NOT AVAILABLE] PHP $new is not in the new package source either."
            return 1
        fi
    fi

    plan_php_change_packages "$PHP_CHANGE_OLD" "$new" "$RECORD_DATABASE_ENGINE"

    # Packages from the retired PPA (maybe built for another Ubuntu
    # release) must not be mixed in.
    if [[ "${#INSTALL_PACKAGES[@]}" -gt 0 && -n "$(get_ondrej_ppa_files)" ]]; then
        echo "[BLOCKED] The old PPA (ppa:ondrej/php) is still an active package source:"
        get_ondrej_ppa_files | sed 's/^/          /'
        echo "          apt could install PHP $new from it instead of $SURY_PHP_URL."
        echo "          Disable it first: ./install.sh --php-source"
        return 1
    fi

    if [[ "${#INSTALL_PACKAGES[@]}" -gt 0 ]] && ! simulate_apt_package_installation > /dev/null; then
        echo "[BLOCKED] apt cannot install the packages of PHP $new:"
        simulate_apt_package_installation | tail -n 15 | sed 's/^/  /'
        return 1
    fi

    # Composer can only run with the new PHP once it is installed.
    if is_php_cli_installed "$new"; then
        if ! failures="$(check_platform_requirements "$RECORD_PROJECT_PATH" "$new")"; then
            echo "[BLOCKED] The installed packages do not accept PHP $new:"
            printf '%s\n' "$failures" | sed 's/^/  /'
            echo "  Update them first (for example ./install.sh --update $machine_name), then try again."
            return 1
        fi

        platform_checked=1
    fi

    PHP_CHANGE_HAS_LAUNCHERS=0
    PHP_CHANGE_HAS_START=0
    is_generated_file "$RECORD_PROJECT_PATH/drush" && PHP_CHANGE_HAS_LAUNCHERS=1
    is_generated_file "$RECORD_PROJECT_PATH/start" && PHP_CHANGE_HAS_START=1
    package_count="${#INSTALL_PACKAGES[@]}"

    # ---- Plan ----
    echo
    echo "======================================"
    echo "  Change PHP: $machine_name"
    echo "======================================"
    echo
    echo "PHP:          $PHP_CHANGE_OLD -> $new (Drupal $current supports it)"

    if [[ "$package_count" -gt 0 ]]; then
        echo "Packages:     install ${INSTALL_PACKAGES[*]}"
    else
        echo "Packages:     PHP $new and its extensions are installed"
    fi

    if [[ "${#PHP_CHANGE_MISSING_PACKAGES[@]}" -gt 0 ]]; then
        echo "              [WARNING] Not available for PHP $new: ${PHP_CHANGE_MISSING_PACKAGES[*]}"
        echo "              The site may need these extensions; check it carefully afterwards."
    fi

    if [[ "$platform_checked" -eq 1 ]]; then
        echo "Composer:     the installed packages accept PHP $new"
    else
        echo "Composer:     checked right after PHP $new is installed (stops if a package refuses it)"
    fi

    echo "PHP-FPM:      new pool $PHP_CHANGE_NEW_POOL"
    echo "              socket $PHP_CHANGE_NEW_SOCKET"
    echo "Nginx:        $PHP_CHANGE_SITE_FILE"
    echo "              fastcgi_pass $PHP_CHANGE_OLD_PASS -> unix:$PHP_CHANGE_NEW_SOCKET ($count line(s))"

    if [[ "$RECORD_MANAGED_BY" == "adopted" ]] && is_installer_created_pool "$PHP_CHANGE_OLD_POOL"; then
        echo "Old pool:     removed after the site works ($PHP_CHANGE_OLD_POOL, created by an earlier --php)"
    elif [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        echo "Old pool:     kept (${PHP_CHANGE_OLD_POOL:-not found}); the installer did not create it"
        echo
        echo "[ADOPTED] The installer did not create this project. Only the fastcgi_pass"
        echo "          line above changes in its Nginx site; the new pool copies the user,"
        echo "          group and php_value settings of the old one. A copy of the site file"
        echo "          is kept, and everything is restored if the site does not work."
    else
        echo "Old pool:     removed after the site works ($PHP_CHANGE_OLD_POOL)"
    fi

    if [[ "$PHP_CHANGE_HAS_LAUNCHERS" -eq 1 ]]; then
        if [[ "$PHP_CHANGE_HAS_START" -eq 1 ]]; then
            echo "Launchers:    ./drush, ./composer and ./start are rewritten for PHP $new"
        else
            echo "Launchers:    ./drush and ./composer are rewritten for PHP $new"
        fi
    fi

    platform_php="$(get_composer_platform_php "$RECORD_PROJECT_PATH" "$PHP_CHANGE_OLD")"

    if [[ -n "$platform_php" ]]; then
        echo
        echo "[INFO] composer.json has config.platform.php = $platform_php: Composer keeps"
        echo "       choosing packages for PHP $platform_php until you change it."
    fi

    echo
    echo "Not changed:  code, database, the system's default \"php\" command."

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        echo "[DRY RUN] Nothing was changed."
        return 0
    fi

    if ! confirm_php_change "$machine_name"; then
        echo "Name does not match. Cancelled; nothing was changed."
        return 1
    fi

    require_sudo || return 1

    # ---- Packages ----
    if [[ "$package_count" -gt 0 ]]; then
        echo
        execute_apt_package_installation || return 1

        if ! failures="$(check_platform_requirements "$RECORD_PROJECT_PATH" "$new")"; then
            echo "[BLOCKED] The installed packages do not accept PHP $new:"
            printf '%s\n' "$failures" | sed 's/^/  /'
            echo "  PHP $new stays installed; the project was not changed."
            return 1
        fi

        echo "[OK] Composer: the installed packages accept PHP $new"

        # Composer forgets the cached sudo password when it starts.
        echo "Composer cleared sudo's cached password; it is needed once more."
        require_sudo || return 1
    fi

    if ! check_php_extensions "$new" "${REQUIRED_PHP_EXTENSIONS[@]}"; then
        echo "[BLOCKED] PHP $new is missing extensions Drupal needs (see above). Nothing was changed."
        return 1
    fi

    # ---- Backup of what is changed ----
    PHP_CHANGE_BACKUP_DIR="$(get_backup_base_dir)/${machine_name}-php-$(date +%Y%m%d-%H%M%S)"

    # The copy belongs to the developer: only reading the site needs sudo.
    # shellcheck disable=SC2024
    if ! run_as_project_user "$PROJECT_USER" install -d -m 0700 "$PHP_CHANGE_BACKUP_DIR" ||
       ! sudo cat -- "$PHP_CHANGE_SITE_FILE" > "$PHP_CHANGE_BACKUP_DIR/nginx-site.conf" ||
       ! backup_launchers; then
        echo "[ERROR] Could not back up the configuration to $PHP_CHANGE_BACKUP_DIR. Nothing was changed."
        return 1
    fi

    echo "[OK] Copies of the configuration: $PHP_CHANGE_BACKUP_DIR"

    local status=0

    # From here on the project changes: Ctrl+C restores it first.
    trap 'interrupt_php_change' INT TERM
    perform_php_change || status=$?
    trap - INT TERM

    return "$status"
}

# The changing part of --php. Uses the variables of run_change_php.
perform_php_change() {
    if ! install_new_pool "$machine_name" "$new" ||
       ! wait_for_socket "$PHP_CHANGE_NEW_SOCKET" ||
       ! switch_nginx_site; then
        rollback_php_change
        return 1
    fi

    if [[ "$PHP_CHANGE_HAS_LAUNCHERS" -eq 1 ]] && ! rewrite_launchers "$new"; then
        rollback_php_change
        return 1
    fi

    if ! verify_php_change; then
        rollback_php_change
        return 1
    fi

    # ---- Done: old pool, registry ----
    if [[ "$RECORD_MANAGED_BY" != "adopted" ]] || is_installer_created_pool "$PHP_CHANGE_OLD_POOL"; then
        remove_old_pool
    elif [[ -n "$PHP_CHANGE_OLD_POOL" ]]; then
        echo "[INFO] The old pool is unchanged: $PHP_CHANGE_OLD_POOL"
    fi

    set_project_field "$record" php_version "$new" &&
    set_project_field "$record" php_fpm_pool "$PHP_CHANGE_NEW_POOL" &&
    set_project_field "$record" php_fpm_socket "$PHP_CHANGE_NEW_SOCKET" ||
        echo "[WARNING] The registry could not be updated: $record"

    if [[ "$RECORD_MANAGED_BY" == "adopted" ]]; then
        set_project_field "$record" support "$(get_project_support "$current" "$new")" || true
    fi

    report_php_setting_differences "$PHP_CHANGE_OLD" "$new"

    echo
    echo "[DONE] $machine_name: PHP $PHP_CHANGE_OLD -> $new"
    echo "Copies of the old configuration: $PHP_CHANGE_BACKUP_DIR"

    if [[ "$PHP_CHANGE_HAS_LAUNCHERS" -eq 1 ]]; then
        echo "Use ./drush and ./composer: they run with PHP $new."
    else
        echo "Run Drush and Composer with PHP $new, e.g.: php$new vendor/bin/drush status"
    fi
}
