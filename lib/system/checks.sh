#!/usr/bin/env bash

# Administrator rights, the user running the installer, and what is
# installed (Composer, Nginx, PHP and its extensions).

require_sudo() {
    echo
    echo "Administrator privileges are required"
    echo "for system, database and web server operations."
    echo
    echo "You will be asked for your Linux user password once."
    echo

    if ! sudo -v; then
        echo
        echo "Administrator authentication failed."
        echo "Installation cancelled."
        return 1
    fi

    echo
    echo "✓ Administrator privileges confirmed."
}

# --------------------------------------------------
# Check whether Composer is installed
# --------------------------------------------------

is_composer_installed() {
    command -v composer >/dev/null 2>&1
}

# --------------------------------------------------
# Check whether Nginx is installed
# --------------------------------------------------

is_nginx_installed() {
    command -v nginx >/dev/null 2>&1
}

# --------------------------------------------------
# Check whether selected PHP-FPM is installed
# --------------------------------------------------

is_php_fpm_installed() {
    local php_version="$1"

    [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || return 2

    dpkg-query -W -f='${Status}' "php${php_version}-fpm" 2>/dev/null |
        grep -qx "install ok installed"
}

# --------------------------------------------------
# Check whether selected PHP CLI is installed
# --------------------------------------------------

is_php_cli_installed() {
    local php_version="$1"

    [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || return 2

    command -v "php${php_version}" >/dev/null 2>&1
}

# --------------------------------------------------
# Check whether a PHP extension is loaded
# --------------------------------------------------

is_php_extension_loaded() {
    local php_version="$1"
    local extension="$2"

    [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || return 2
    [[ "$extension" =~ ^[a-zA-Z0-9_]+$ ]] || return 2

    "php${php_version}" -r \
        "exit(extension_loaded('$extension') ? 0 : 1);" \
        2>/dev/null
}

# --------------------------------------------------
# Check required PHP extensions
# --------------------------------------------------

check_php_extensions() {
    local php_version="$1"
    shift

    local extension
    local missing=0

    for extension in "$@"; do
        if is_php_extension_loaded "$php_version" "$extension"; then
            # Only listed one by one with --verbose; missing ones always.
            if [[ "${VERBOSE:-0}" == "1" ]]; then
                echo "[OK] $extension"
            fi
        else
            echo "[MISSING] $extension"
            missing=1
        fi
    done

    return "$missing"
}


# --------------------------------------------------
# Detect the real (non-root) user running the installer
# --------------------------------------------------

get_runtime_user() {
    local runtime_user

    if [[ "$(id -u)" -eq 0 ]]; then
        runtime_user="${SUDO_USER:-}"

        if [[ -z "$runtime_user" || "$runtime_user" == "root" ]]; then
            echo "[ERROR] Run the installer as a normal user, not as root." >&2
            return 1
        fi
    else
        runtime_user="$(id -un)"
    fi

    if [[ ! "$runtime_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Unsupported username: $runtime_user" >&2
        return 1
    fi

    printf '%s\n' "$runtime_user"
}
