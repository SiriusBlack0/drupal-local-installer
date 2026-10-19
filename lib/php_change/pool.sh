#!/usr/bin/env bash

# PHP-FPM pool and Nginx site of a project during a PHP change.

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
    # Read in lib/php_change/php_change.sh (rollback).
    # shellcheck disable=SC2034
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

    # Read in lib/php_change/php_change.sh (rollback).
    # shellcheck disable=SC2034
    PHP_CHANGE_SITE_SWITCHED=1

    if ! run_logged "Checking Nginx configuration" sudo nginx -t ||
       ! run_logged "Reloading Nginx" reload_or_start_service nginx; then
        return 1
    fi

    echo "[OK] Nginx site uses the new socket: $PHP_CHANGE_NEW_SOCKET"
}

# A pool of an adopted project that the installer itself created earlier
# (first line PHP_CHANGE_POOL_MARKER) and that the registry records.
is_installer_created_pool() {
    [[ -n "$1" && -f "$1" && "$1" == "$RECORD_POOL" ]] &&
        [[ "$(head -n 1 "$1")" == "$PHP_CHANGE_POOL_MARKER" ]]
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
