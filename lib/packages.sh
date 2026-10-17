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

execute_apt_package_installation() {
    if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "[OK] No packages to install."
        return 0
    fi

    echo "Installing required APT packages..."

    # --no-remove: apt aborts instead of removing anything.
    if sudo apt-get install --no-remove -- "${INSTALL_PACKAGES[@]}"; then
        echo "[OK] APT packages installed successfully."
        return 0
    fi

    echo "[ERROR] APT package installation failed."
    return 1
}