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
# Read in lib/php_change/pool.sh.
# shellcheck disable=SC2034
PHP_CHANGE_POOL_MARKER="; Created by drupal-local-installer (--php)"

# Package suffixes of the old PHP that are not copied to the new one.
PHP_CHANGE_SKIP_SUFFIXES="dev dbgsym phpdbg cgi"


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

# Ctrl+C (or kill) while the project is being changed: undo, then stop.
interrupt_php_change() {
    trap '' INT TERM
    to_console
    echo
    echo "[INTERRUPTED] Stopping the PHP change and restoring the project..."
    rollback_php_change
    exit 130
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

# PHPCompatibility found errors: the user decides (the checker is advice).
confirm_php_findings() {
    local answer

    echo
    read -r -p "PHPCompatibility reported errors (see above). Change PHP anyway? [y/N]: " answer &&
        [[ "$answer" =~ ^[Yy]$ ]]
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
    local platform_checked=0
    local platform_php
    local package_count
    local old_php_problem=""
    local compat_status=0

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

    # The checks need the new PHP: when it is not installed yet, they run
    # right after its packages are installed.
    if is_php_cli_installed "$new"; then
        compat_status=0
        run_php_compat_checks "$new" "$web_root" "$current" "$machine_name" || compat_status=$?
        platform_checked=1

        if [[ "$compat_status" -eq 1 ]]; then
            echo
            echo "[BLOCKED] The checks above show that the site would not work with PHP $new."
            echo "          Nothing was changed."
            return 1
        fi
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
        if [[ -n "$PHP_COMPAT_FINDINGS" ]]; then
            echo "Checks:       passed; PHPCompatibility found $PHP_COMPAT_FINDINGS (see above)"
        else
            echo "Checks:       passed (see above)"
        fi
    else
        echo "Checks:       run right after PHP $new is installed (Composer, syntax of the"
        echo "              custom code, trial run with Drush, PHPCompatibility); the change"
        echo "              stops there if the site would not work with PHP $new"
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
    echo "After:        Drush and the front page are checked with PHP $new, and new"
    echo "              errors in the Drupal log are reported."

    if [[ "$REMOVE_DRY_RUN" -eq 1 ]]; then
        echo
        print_manual_php_checks "$machine_name"
        echo
        echo "[DRY RUN] Nothing was changed."
        return 0
    fi

    if [[ "$compat_status" -eq 2 ]] && ! confirm_php_findings; then
        echo "Cancelled; nothing was changed."
        return 1
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

        compat_status=0
        run_php_compat_checks "$new" "$web_root" "$current" "$machine_name" || compat_status=$?

        if [[ "$compat_status" -eq 1 ]]; then
            echo
            echo "[BLOCKED] The checks above show that the site would not work with PHP $new."
            echo "          PHP $new stays installed; the project was not changed."
            return 1
        fi

        if [[ "$compat_status" -eq 2 ]] && ! confirm_php_findings; then
            echo "Cancelled. PHP $new stays installed; the project was not changed."
            return 1
        fi

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
    local watchdog_since

    watchdog_since="$(get_last_watchdog_error_id "$PHP_CHANGE_OLD")"

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

    report_new_watchdog_errors "$watchdog_since"
    report_php_setting_differences "$PHP_CHANGE_OLD" "$new"

    echo
    echo "[DONE] $machine_name: PHP $PHP_CHANGE_OLD -> $new"
    echo "Copies of the old configuration: $PHP_CHANGE_BACKUP_DIR"

    if [[ "$PHP_CHANGE_HAS_LAUNCHERS" -eq 1 ]]; then
        echo "Use ./drush and ./composer: they run with PHP $new."
    else
        echo "Run Drush and Composer with PHP $new, e.g.: php$new vendor/bin/drush status"
    fi

    echo
    print_manual_php_checks "$machine_name"
}
