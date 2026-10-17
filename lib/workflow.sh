#!/usr/bin/env bash

# ==================================================
# Phase 3: installation
#
# Every resource this run creates is recorded in CREATED_RESOURCES.
# If a later step fails, rollback_installation removes them again in
# reverse order, so a failed run leaves nothing half-finished behind.
# ==================================================

CREATED_RESOURCES=()

record_created() {
    CREATED_RESOURCES+=("$1")
}

rollback_installation() {
    local index
    local resource
    local failed=0

    if [[ "${#CREATED_RESOURCES[@]}" -eq 0 ]]; then
        return 0
    fi

    echo
    echo "Rolling back what this run created..."

    for (( index=${#CREATED_RESOURCES[@]} - 1; index >= 0; index-- )); do
        resource="${CREATED_RESOURCES[$index]}"

        case "$resource" in
            nginx_site)
                remove_nginx_site "$PROJECT_MACHINE_NAME" ||
                    { echo "[WARNING] Remove the Nginx site manually: $(get_nginx_config_path "$PROJECT_MACHINE_NAME")"; failed=1; }
                ;;
            php_fpm_pool)
                remove_php_fpm_pool "$PROJECT_MACHINE_NAME" "$PHP_VERSION" ||
                    { echo "[WARNING] Remove the PHP-FPM pool manually: $(get_php_fpm_pool_config_path "$PROJECT_MACHINE_NAME" "$PHP_VERSION")"; failed=1; }
                ;;
            database)
                remove_project_database "$DATABASE_ENGINE" "$DATABASE_NAME" "$DATABASE_USER" > /dev/null ||
                    { echo "[WARNING] Remove the database '$DATABASE_NAME' and user '$DATABASE_USER' manually."; failed=1; }
                ;;
            project_directory)
                remove_project_directory "$PROJECT_PATH" ||
                    { echo "[WARNING] Remove the directory manually: sudo rm -rf -- '$PROJECT_PATH'"; failed=1; }
                ;;
        esac
    done

    CREATED_RESOURCES=()

    if [[ "$failed" -eq 0 ]]; then
        echo "[OK] Rollback completed."
    fi
}

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

# PHP-FPM pool first: Nginx points to its socket.
setup_web_server() {
    if ! install_php_fpm_pool "$PROJECT_MACHINE_NAME" "$PHP_VERSION" "$PROJECT_USER"; then
        return 1
    fi

    record_created php_fpm_pool

    if ! install_nginx_site "$PROJECT_MACHINE_NAME" "$PROJECT_PATH" "$PHP_VERSION"; then
        return 1
    fi

    record_created nginx_site

    verify_nginx_site "$PROJECT_MACHINE_NAME"
}

run_installation_workflow() {
    CREATED_RESOURCES=()

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

    # provision_drupal_project removes its own directory on failure.
    if ! provision_drupal_project \
        "$DRUPAL_VERSION" \
        "$PROJECT_PATH" \
        "$PHP_VERSION" \
        "$PROJECT_USER"; then
        echo "[ERROR] Drupal provisioning failed."
        return 1
    fi

    record_created project_directory

    step "Creating the database"

    # The database functions remove what they created themselves.
    if ! setup_project_database; then
        echo "[ERROR] Database creation failed."
        rollback_installation
        return 1
    fi

    record_created database

    step "Configuring the web server"

    if ! setup_web_server; then
        echo "[ERROR] Web server configuration failed."
        rollback_installation
        return 1
    fi

    step "Installing the Drupal site"

    if ! install_drupal_site \
        "$PROJECT_PATH" \
        "$PROJECT_USER" \
        "$PROJECT_NAME" \
        "$ADMIN_USER" \
        "$ADMIN_MAIL" \
        "$ADMIN_PASSWORD"; then
        echo "[ERROR] Drupal site installation failed."
        rollback_installation
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
