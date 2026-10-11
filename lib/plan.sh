#!/usr/bin/env bash

# --------------------------------------------------
# Installation plan summary
# --------------------------------------------------

# shellcheck disable=SC2034
prepare_installation_plan() {

    echo
    echo "======================================"
    echo "          Installation Plan"
    echo "======================================"
    echo

    if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "No additional packages required."
    else
        echo "Packages to install:"

        for package in "${INSTALL_PACKAGES[@]}"; do
            echo "  - $package"
        done
    fi

    echo

    if [ "${#INSTALL_SERVICES_TO_START[@]}" -eq 0 ]; then
        echo "No installed services need to be started."
    else
        echo "Services to start:"

        for service in "${INSTALL_SERVICES_TO_START[@]}"; do
            echo "  - $service"
        done
    fi

    echo

    if [ "${#INSTALL_SERVICES_AFTER_INSTALL[@]}" -eq 0 ]; then
        echo "No services need to be started after installation."
    else
        echo "Services to start after installation:"

        for service in "${INSTALL_SERVICES_AFTER_INSTALL[@]}"; do
            echo "  - $service"
        done
    fi

    echo
    echo "======================================"

    echo
    echo "Checking APT repository compatibility..."

    if check_apt_repository_compatibility; then
        APT_REPOSITORIES_COMPATIBLE=true
    else
        APT_REPOSITORIES_COMPATIBLE=false
    fi

    # --------------------------------------------------
    # Check installation package availability
    # --------------------------------------------------

    PACKAGES_AVAILABLE=true

    if [ "${#INSTALL_PACKAGES[@]}" -gt 0 ]; then
        echo
        echo "Checking package availability..."

        if check_install_packages_availability; then
            echo "[OK] All planned packages are available."
        else
            PACKAGES_AVAILABLE=false
            echo
            echo "[PENDING] Additional repositories may be required."

            if [ "${#UNAVAILABLE_PACKAGES[@]}" -gt 0 ]; then
                echo
                echo "Packages requiring additional sources:"

                for package in "${UNAVAILABLE_PACKAGES[@]}"; do
                    echo "  - $package"
                done
            fi
        fi
    fi

}
