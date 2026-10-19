#!/usr/bin/env bash

# Ubuntu release, APT packages of the plan and APT repositories.

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
