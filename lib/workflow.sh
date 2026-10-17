#!/usr/bin/env bash

# Creates the project database for the selected engine.
# Called directly (not through run_logged) so that the database
# password never appears in the log or in a process list.
setup_project_database() {
    log_line "Database: $DATABASE_ENGINE (credentials are not logged)"

    case "$DATABASE_ENGINE" in
        sqlite)
            provision_project_database \
                sqlite \
                "$SQLITE_DATABASE_PATH" \
                "$PROJECT_USER"
            ;;
        *)
            provision_project_database \
                "$DATABASE_ENGINE" \
                "$DATABASE_NAME" \
                "$DATABASE_USER" \
                "$DATABASE_PASSWORD"
            ;;
    esac
}

run_installation_workflow() {
    step "Installing required packages"
    prepare_installation_plan

    if ! execute_installation_plan; then
        echo "[ERROR] Installation execution failed."
        return 1
    fi

    step "Verifying the environment"

    if ! verify_environment_ready; then
        echo "[BLOCKED] Drupal provisioning cannot continue."
        return 1
    fi

    step "Creating the Drupal project"

    if ! provision_drupal_project \
        "$DRUPAL_VERSION" \
        "$PROJECT_PATH" \
        "$PHP_VERSION" \
        "$PROJECT_USER"; then
        echo "[ERROR] Drupal provisioning failed."
        return 1
    fi

    step "Creating the database"

    # The database functions roll back what they created themselves;
    # here the project directory from the previous step is removed too.
    if ! setup_project_database; then
        echo "[ERROR] Database creation failed."
        echo "Rolling back: removing $PROJECT_PATH..."

        if remove_project_directory "$PROJECT_PATH"; then
            echo "[OK] Rollback completed."
        else
            echo "[WARNING] Rollback failed. Remove the directory manually:"
            echo "  sudo rm -rf -- '$PROJECT_PATH'"
        fi

        return 1
    fi

    # ./start is a convenience: if it cannot be written, the project
    # itself is still fine, so this is only a warning.
    if ! create_start_script \
        "$PROJECT_PATH" \
        "$PHP_VERSION" \
        "$DATABASE_ENGINE" \
        "$PROJECT_MACHINE_NAME" \
        "$PROJECT_USER"; then
        echo "[WARNING] ./start could not be created; start the services manually."
    fi

    return 0
}
