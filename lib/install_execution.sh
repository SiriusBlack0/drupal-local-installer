#!/usr/bin/env bash

# --------------------------------------------------
# Package installation readiness
# --------------------------------------------------

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
    read -r -p "Continue despite these warnings? [y/N]: " CONTINUE_ANYWAY

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

echo
echo "Preparing package installation..."

if [ "$PACKAGES_AVAILABLE" = false ]; then
    echo "[SKIPPED] Package installation cannot proceed."
    echo "Some required packages are unavailable."

elif [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
    echo "[OK] No additional packages need installation."

else
    echo "[READY] Required packages are available."
    echo

    read -r -p "Install required APT packages? [y/N]: " INSTALL_CHOICE

    case "$INSTALL_CHOICE" in
        y|Y|yes|YES)
            echo "[APPROVED] Package installation approved."
            echo

            if simulate_apt_package_installation; then
                echo
                echo "[OK] APT installation simulation completed successfully."
                echo

                read -r -p "Proceed with actual package installation? [y/N]: " CONFIRM_INSTALL

                case "$CONFIRM_INSTALL" in
                    y|Y|yes|YES)
                        if execute_apt_package_installation; then
                            echo "[OK] Package installation completed."
                        else
                            echo "[ERROR] Package installation failed."
                            exit 1
                        fi
                        ;;
                    *)
                        echo "[SKIPPED] Actual package installation cancelled."
                        ;;
                esac

            else
                echo
                echo "[ERROR] APT installation simulation failed."
                exit 1
            fi
            ;;
        *)
            echo "[SKIPPED] Package installation declined."
            ;;
    esac
fi
