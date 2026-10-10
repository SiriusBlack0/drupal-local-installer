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

    echo "Simulating APT package installation..."

    apt-get --simulate install -- "${INSTALL_PACKAGES[@]}"
}

execute_apt_package_installation() {
    if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "[OK] No packages to install."
        return 0
    fi

    echo "Installing required APT packages..."

    if sudo apt-get install -- "${INSTALL_PACKAGES[@]}"; then
        echo "[OK] APT packages installed successfully."
        return 0
    fi

    echo "[ERROR] APT package installation failed."
    return 1
}