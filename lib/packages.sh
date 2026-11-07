#!/usr/bin/env bash

# --------------------------------------------------
# Install required APT packages
# --------------------------------------------------
install_apt_packages() {
    local package

    if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "No packages need installation."
        return 0
    fi

    echo "Packages selected for installation:"

    for package in "${INSTALL_PACKAGES[@]}"; do
        echo "  - $package"
    done

    echo
    echo "Checking package availability..."

    if ! check_install_packages_availability; then
        echo
        echo "[PENDING] Some packages require additional package sources."
        return 1
    fi

    echo
    echo "[READY] All packages are available."
    echo "[PENDING] Installation requires user approval."
}

simulate_apt_package_installation() {
    if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "[OK] No packages to install."
        return 0
    fi

    local output
    local removals

    echo "Simulating APT package installation..."

    if ! output="$(apt-get --simulate install -- "${INSTALL_PACKAGES[@]}" 2>&1)"; then
        printf '%s\n' "$output"
        return 1
    fi

    printf '%s\n' "$output"

    # The installer never removes packages: other projects may need them.
    # Example: mysql-server and mariadb-server replace each other.
    removals="$(printf '%s\n' "$output" | awk '$1 == "Remv" { printf "%s ", $2 }')"

    if [[ -n "$removals" ]]; then
        echo
        echo "[BLOCKED] Installing ${INSTALL_PACKAGES[*]} would REMOVE: $removals"
        echo "          The installer never removes packages, because other"
        echo "          projects may depend on them. MariaDB and MySQL, for"
        echo "          example, cannot be installed side by side: choose the"
        echo "          database that is already installed."
        return 1
    fi
}

# The commands whose system-wide default apt may switch when it installs
# another PHP version ("update-alternatives ... in auto mode").
PHP_ALTERNATIVES=(php phar phar.phar)

# The current target of an alternative ("/usr/bin/php8.3"); empty when
# there is none or update-alternatives is missing.
get_alternative_value() {
    command -v update-alternatives > /dev/null 2>&1 || return 0
    update-alternatives --query "$1" 2>/dev/null | awk '/^Value:/ { print $2; exit }'
}

# apt never changes which PHP the plain "php" command runs: what it
# switched is set back (other projects and scripts rely on it).
restore_php_alternatives() {
    local -n before_values="$1"
    local name
    local now

    for name in "${PHP_ALTERNATIVES[@]}"; do
        [[ -n "${before_values[$name]:-}" ]] || continue
        now="$(get_alternative_value "$name")"
        [[ -n "$now" && "$now" != "${before_values[$name]}" ]] || continue

        if sudo update-alternatives --set "$name" "${before_values[$name]}" > /dev/null 2>&1; then
            echo "[OK] The system's default $name stays ${before_values[$name]} (apt had switched it to $now)"
        else
            echo "[WARNING] apt switched the system's default $name to $now; setting it back failed:"
            echo "          sudo update-alternatives --set $name ${before_values[$name]}"
        fi
    done
}

execute_apt_package_installation() {
    local -A alternatives_before=()
    local name
    local status=0

    if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "[OK] No packages to install."
        return 0
    fi

    for name in "${PHP_ALTERNATIVES[@]}"; do
        # Read by restore_php_alternatives through a nameref.
        # shellcheck disable=SC2034
        alternatives_before["$name"]="$(get_alternative_value "$name")"
    done

    echo "Installing required APT packages..."

    # The packages were approved after the simulation, so apt does not ask
    # again (its question would read the next answer meant for the
    # installer). --no-remove: apt aborts instead of removing anything.
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove -- "${INSTALL_PACKAGES[@]}" || status=$?

    restore_php_alternatives alternatives_before

    if [[ "$status" -eq 0 ]]; then
        echo "[OK] APT packages installed successfully."
        return 0
    fi

    echo "[ERROR] APT package installation failed."
    return 1
}

# "14 newly installed" from a simulation: how many packages apt installs,
# dependencies included.
count_simulated_installs() {
    apt-get --simulate install -- "${INSTALL_PACKAGES[@]}" 2>/dev/null | awk '$1 == "Inst" { n++ } END { print n + 0 }'
}