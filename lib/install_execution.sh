#!/usr/bin/env bash

# --------------------------------------------------
# Package installation readiness
# --------------------------------------------------

check_package_installation_readiness() {
    echo
    echo "Checking package installation readiness..."

    if [ "$APT_REPOSITORIES_COMPATIBLE" = false ]; then
        echo "[WARNING] Some APT repositories target another Ubuntu release."
    fi

    if [ "$PACKAGES_AVAILABLE" = false ]; then
        echo "[ACTION REQUIRED] Some packages are unavailable."
    fi

    if [ "$APT_REPOSITORIES_COMPATIBLE" = false ] || \
       [ "$PACKAGES_AVAILABLE" = false ]; then

        echo

        if ! read -r -p "Continue despite these warnings? [y/N]: " CONTINUE_ANYWAY; then
            echo
            echo "[CANCELLED] Installation cancelled by user."
            exit 0
        fi

        case "$CONTINUE_ANYWAY" in
            y|Y|yes|YES)
                echo "[OK] User accepted the warnings."
                ;;
            *)
                echo "[CANCELLED] Installation cancelled by user."
                exit 0
                ;;
        esac
    else
        echo "[READY] Package availability and repository checks passed."
    fi
}


prepare_package_installation() {

    echo
    echo "Preparing package installation..."

    if [ "$APT_REPOSITORIES_COMPATIBLE" = false ] &&
    [ "${#INSTALL_PACKAGES[@]}" -gt 0 ]; then
        echo "[BLOCKED] Incompatible APT repositories detected."
        echo "[ERROR] Package installation cannot proceed safely."
        return 1
    fi

    if [ "$PACKAGES_AVAILABLE" = false ]; then
        echo "[BLOCKED] Package installation cannot proceed."
        echo "[ERROR] Some required packages are unavailable."
        echo "[INFO] Resolve the missing dependencies before installing Drupal."
        return 1

    elif [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
        echo "[OK] No additional packages need installation."

    else
        echo "[READY] Required packages are available."
        echo

        if ! read -r -p "Install required APT packages? [y/N]: " INSTALL_CHOICE; then
            echo
            INSTALL_CHOICE="n"
        fi

        case "$INSTALL_CHOICE" in
            y|Y|yes|YES)
                echo "[APPROVED] Package installation approved."
                echo

                if simulate_apt_package_installation; then
                    echo
                    echo "[OK] APT installation simulation completed successfully."
                    echo

                    if ! read -r -p "Proceed with actual package installation? [y/N]: " CONFIRM_INSTALL; then
                        echo
                        CONFIRM_INSTALL="n"
                    fi

                    case "$CONFIRM_INSTALL" in
                        y|Y|yes|YES)
                            if execute_apt_package_installation; then
                                echo "[OK] Package installation completed."
                            else
                                echo "[ERROR] Package installation failed."
                                return 1
                            fi
                            ;;
                        *)
                            echo "[BLOCKED] Package installation declined."
                            echo "[INFO] Required dependencies must be installed before Drupal."
                            return 1
                            ;;
                    esac

                else
                    echo
                    echo "[ERROR] APT installation simulation failed."
                    return 1
                fi
                ;;
            *)
                echo "[BLOCKED] Package installation declined."
                echo "[INFO] Required dependencies must be installed before Drupal."
                return 1
                ;;
        esac
    fi
}

execute_installation_plan() {

    check_package_installation_readiness

    if ! prepare_package_installation; then
        echo "[ERROR] Package preparation failed. Installation stopped."
        return 1
    fi

    echo
    echo "Starting required services..."

    if ! start_planned_services; then
        echo "[ERROR] Required services could not be started."
        return 1
    fi

    echo "[OK] All planned services are running."
}