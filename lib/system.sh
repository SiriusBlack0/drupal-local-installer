#!/usr/bin/env bash

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
# Service management (systemd or SysV "service")
# --------------------------------------------------

# Native Ubuntu runs systemd; WSL may not. This is the standard
# systemd check (same test that sd_booted() performs).
has_systemd() {
    [[ -d /run/systemd/system ]]
}

is_service_active() {
    local service="$1"

    if has_systemd; then
        systemctl is-active --quiet "$service"
    else
        service "$service" status >/dev/null 2>&1
    fi
}

run_service_start() {
    local service="$1"

    if has_systemd; then
        sudo systemctl start "$service"
    else
        sudo service "$service" start
    fi
}

# --------------------------------------------------
# Check whether PHP-FPM service is running
# --------------------------------------------------

is_php_fpm_running() {
    local php_version="$1"

    [[ "$php_version" =~ ^[0-9]+\.[0-9]+$ ]] || return 2

    is_service_active "php${php_version}-fpm"
}

# --------------------------------------------------
# Check whether Nginx service is running
# --------------------------------------------------

is_nginx_running() {
    is_service_active nginx
}

# --------------------------------------------------
# Check whether a database service is running
# --------------------------------------------------

is_database_service_running() {
    local database_engine="$1"
    local service_name

    case "$database_engine" in
        mariadb)
            service_name="mariadb"
            ;;
        mysql)
            service_name="mysql"
            ;;
        postgresql)
            service_name="postgresql"
            ;;
        sqlite)
            return 0
            ;;
        *)
            return 2
            ;;
    esac

    is_service_active "$service_name"
}

# --------------------------------------------------
# Installation plan
# --------------------------------------------------

INSTALL_PACKAGES=()

add_install_package() {
    local package="$1"
    local existing

    for existing in "${INSTALL_PACKAGES[@]}"; do
        if [ "$existing" = "$package" ]; then
            return 0
        fi
    done

    INSTALL_PACKAGES+=("$package")
}

# --------------------------------------------------
# Check whether an APT package is available
# --------------------------------------------------

is_apt_package_available() {
    local package="$1"
    local candidate

    [[ "$package" =~ ^[a-zA-Z0-9.+-]+$ ]] || return 2

    candidate="$(apt-cache policy "$package" |
        awk '/Candidate:/ {print $2; exit}')"

    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

# --------------------------------------------------
# Check installation plan package availability
# --------------------------------------------------

check_install_packages_availability() {
    local package
    local unavailable=0

    UNAVAILABLE_PACKAGES=()

    for package in "${INSTALL_PACKAGES[@]}"; do
        if is_apt_package_available "$package"; then
            echo "[AVAILABLE] $package"
        else
            echo "[UNAVAILABLE] $package"
            add_unavailable_package "$package"
            unavailable=1
        fi
    done

    return "$unavailable"
}
# --------------------------------------------------
# Get Ubuntu version codename
# --------------------------------------------------

get_ubuntu_codename() {
    local distro_id
    local codename

    [ -f /etc/os-release ] || return 1

    distro_id=$(
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "$ID"
    )

    codename=$(
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "$VERSION_CODENAME"
    )

    if [ "$distro_id" != "ubuntu" ] || [ -z "$codename" ]; then
        return 1
    fi

    echo "$codename"
}

# --------------------------------------------------
# Get Ubuntu version
# --------------------------------------------------

get_ubuntu_version() {
    (
        # shellcheck source=/dev/null
        . /etc/os-release

        if [ "$ID" != "ubuntu" ] || [ -z "$VERSION_ID" ]; then
            return 1
        fi

        echo "$VERSION_ID"
    )
}

get_linux_distribution() {
    (
        [ -f /etc/os-release ] || return 1

        # shellcheck source=/dev/null
        . /etc/os-release

        printf 'Distribution: %s\n' "$ID"
        printf 'Version: %s\n' "$VERSION_ID"
        printf 'Codename: %s\n' "${VERSION_CODENAME:-unknown}"
    )
}

is_ubuntu_system() {
    local distro_id

    [ -f /etc/os-release ] || return 1

    distro_id=$(
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "$ID"
    )

    [ "$distro_id" = "ubuntu" ]
}

INSTALL_SERVICES_TO_START=()

add_service_to_start() {
    local service="$1"
    local existing

    for existing in "${INSTALL_SERVICES_TO_START[@]}"; do
        if [ "$existing" = "$service" ]; then
            return 0
        fi
    done

    INSTALL_SERVICES_TO_START+=("$service")
}

INSTALL_SERVICES_AFTER_INSTALL=()

add_service_after_install() {
    local service="$1"
    local existing

    for existing in "${INSTALL_SERVICES_AFTER_INSTALL[@]}"; do
        if [ "$existing" = "$service" ]; then
            return 0
        fi
    done

    INSTALL_SERVICES_AFTER_INSTALL+=("$service")
}

get_php_extension_package() {
    local php_version="$1"
    local extension="$2"

    case "$extension" in
        curl)
            echo "php${php_version}-curl"
            ;;
        gd)
            echo "php${php_version}-gd"
            ;;
        mbstring)
            echo "php${php_version}-mbstring"
            ;;
        dom|simplexml|xml)
            echo "php${php_version}-xml"
            ;;
        pdo_mysql)
            echo "php${php_version}-mysql"
            ;;
        pdo_pgsql)
            echo "php${php_version}-pgsql"
            ;;
        pdo_sqlite)
            echo "php${php_version}-sqlite3"
            ;;
        *)
            return 1
            ;;
    esac
}

plan_php_extension_packages() {
    local php_version="$1"
    shift

    local extension
    local package
    local missing=0

    for extension in "$@"; do
        if is_php_extension_loaded "$php_version" "$extension"; then
            continue
        fi

        missing=1

        if package="$(get_php_extension_package "$php_version" "$extension")"; then
            add_install_package "$package"
        else
            echo "[PENDING] No package mapping for PHP extension: $extension"
        fi
    done

    return "$missing"
}

UNAVAILABLE_PACKAGES=()

add_unavailable_package() {
    local package="$1"
    local existing

    for existing in "${UNAVAILABLE_PACKAGES[@]}"; do
        if [ "$existing" = "$package" ]; then
            return 0
        fi
    done

    UNAVAILABLE_PACKAGES+=("$package")
}

get_apt_repository_suites() {
    local file

    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
        [ -f "$file" ] || continue

        case "$file" in
            *.sources)
                awk '
                    BEGIN { RS = ""; FS = "\n" }

                    {
                        enabled = 1
                        suites = ""

                        for (i = 1; i <= NF; i++) {
                            if ($i ~ /^Enabled:[[:space:]]*no[[:space:]]*$/) {
                                enabled = 0
                            }

                            if ($i ~ /^Suites:/) {
                                suites = $i
                                sub(/^Suites:[[:space:]]*/, "", suites)
                            }
                        }

                        if (enabled && suites != "") {
                            print suites
                        }
                    }
                ' "$file"
                ;;

            *.list)
                awk '
                    /^[[:space:]]*deb[[:space:]]/ {
                        for (i = 2; i <= NF; i++) {
                            if ($i ~ /^\[/) {
                                while (i <= NF && $i !~ /\]$/) i++
                                continue
                            }

                            if (i + 1 <= NF) {
                                print $(i + 1)
                            }
                            break
                        }
                    }
                ' "$file"
                ;;
        esac
    done | tr ' ' '\n' | sed '/^$/d' | sort -u
}

get_mismatched_ubuntu_suites() {
    local ubuntu_codename
    local suite

    ubuntu_codename="$(get_ubuntu_codename)" || return 1

    while IFS= read -r suite; do
        case "$suite" in
            noble|noble-*|jammy|jammy-*|focal|focal-*|resolute|resolute-*|oracular|oracular-*|plucky|plucky-*|questing|questing-*)
                if [[ "$suite" != "$ubuntu_codename" &&
                      "$suite" != "$ubuntu_codename"-* ]]; then
                    echo "$suite"
                fi
                ;;
        esac
    done < <(get_apt_repository_suites)
}

check_apt_repository_compatibility() {
    local mismatched_suites

    mismatched_suites="$(get_mismatched_ubuntu_suites)"

    if [ -z "$mismatched_suites" ]; then
        echo "[OK] No mismatched Ubuntu repository suites detected."
        return 0
    fi

    echo "[WARNING] Repository suites from another Ubuntu release detected:"
    echo "$mismatched_suites" | while IFS= read -r suite; do
        echo "  - $suite"
    done

    echo "[WARNING] Review these APT sources before installing packages."

    return 1
}

# --------------------------------------------------
# Start a system service
# --------------------------------------------------

start_system_service() {
    local service="$1"

    if is_service_active "$service"; then
        echo "[OK] Service '$service' is already running."
        return 0
    fi

    echo "[STARTING] Service '$service'..."

    if run_service_start "$service"; then
        if is_service_active "$service"; then
            echo "[OK] Service '$service' started successfully."
            return 0
        fi
    fi

    echo "[ERROR] Failed to start service '$service'."
    return 1
}

# --------------------------------------------------
# Start services from the installation plan
# --------------------------------------------------

start_planned_services() {
    local service
    local existing
    local already_processed
    local -a processed_services=()

    for service in \
        "${INSTALL_SERVICES_TO_START[@]}" \
        "${INSTALL_SERVICES_AFTER_INSTALL[@]}"; do

        already_processed=false

        for existing in "${processed_services[@]}"; do
            if [ "$existing" = "$service" ]; then
                already_processed=true
                break
            fi
        done

        if [ "$already_processed" = true ]; then
            continue
        fi

        processed_services+=("$service")

        if ! start_system_service "$service"; then
            echo "[ERROR] Required service '$service' could not be started."
            return 1
        fi
    done

    return 0
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