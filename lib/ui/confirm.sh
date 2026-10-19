#!/usr/bin/env bash

# Phase 1: final summary, and the entry point of phase 1.

# --------------------------------------------------
# Final configuration summary
# --------------------------------------------------

confirm_installation() {
    while true; do
        echo
        echo "======================================"
        echo "        Project configuration"
        echo "======================================"
        echo
        echo "Project:  $PROJECT_NAME"
        echo "Machine:  $PROJECT_MACHINE_NAME"
        echo "Drupal:   $DRUPAL_VERSION"
        echo "PHP:      $PHP_VERSION [$PHP_STATUS]"
        echo "Database: $DATABASE_ENGINE $DATABASE_VERSION [$DATABASE_STATUS]"

        if [ "$DATABASE_ENGINE" = "sqlite" ]; then
            echo "DB File:  $SQLITE_DATABASE_PATH"
        else
            echo "DB Name:  $DATABASE_NAME"
            echo "DB User:  $DATABASE_USER"
        fi

        if [[ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]]; then
            echo "Admin:    $ADMIN_USER (random password, shown at the end)"
        else
            echo "Admin:    $ADMIN_USER (your password)"
        fi

        echo
        echo "======================================"
        echo

        if ! read -r -p "Proceed with installation? [Y/n]: " PROCEED_CHOICE; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$PROCEED_CHOICE" in
            y|Y|"")
                break
                ;;
            n|N)
                echo "Installation cancelled."
                exit 0
                ;;
            *)
                echo "Please enter y or n."
                ;;
        esac
    done
}

# ==================================================
# Phase 1 entry point
# ==================================================

# Asks every configuration question in order.
# Sourcing this file only defines functions; nothing runs until
# install.sh calls run_configuration_ui.
run_configuration_ui() {
    prompt_project_name

    # Repeat the version choice until the system can run it,
    # or until the user cancels.
    while true; do
        prompt_drupal_version

        echo
        detect_php_requirements

        if resolve_compatible_php_versions; then
            break
        fi

        choose_after_blocked
    done

    prompt_php_version

    echo
    detect_compatible_databases
    prompt_database_selection
    determine_database_install_need

    configure_database_credentials
    configure_admin_account
    confirm_installation
}
