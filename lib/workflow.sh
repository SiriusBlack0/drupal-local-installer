#!/usr/bin/env bash

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

    return 0
}
