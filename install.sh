#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Modules only define functions; main() decides what runs and when.
source "$SCRIPT_DIR/lib/drupal.sh"
source "$SCRIPT_DIR/lib/php.sh"
source "$SCRIPT_DIR/lib/php_fpm.sh"
source "$SCRIPT_DIR/lib/nginx.sh"
source "$SCRIPT_DIR/lib/database.sh"
source "$SCRIPT_DIR/lib/compatibility.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/registry.sh"
source "$SCRIPT_DIR/lib/packages.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/plan.sh"
source "$SCRIPT_DIR/lib/install_execution.sh"
source "$SCRIPT_DIR/lib/readiness.sh"
source "$SCRIPT_DIR/lib/project.sh"
source "$SCRIPT_DIR/lib/workflow.sh"

check_operating_system() {
    echo
    echo "Checking operating system..."

    if ! is_ubuntu_system; then
        echo "[UNSUPPORTED] Only Ubuntu is supported."
        return 1
    fi

    echo "[SUPPORTED] Ubuntu detected."
    get_linux_distribution
}

print_banner() {
    echo
    echo "======================================"
    echo "        Drupal Local Installer"
    echo "======================================"
    echo
}

main() {
    if ! check_operating_system; then
        exit 1
    fi

    print_banner

    # Phase 1: questions only, no system changes.
    run_configuration_ui

    # Phase 2: checks and installation plan, no system changes.
    if ! run_preflight; then
        echo "Installation stopped."
        exit 1
    fi

    # Phase 3: approved installation and project creation.
    if ! run_installation_workflow; then
        echo "[ERROR] Installation workflow failed."
        exit 1
    fi
}

main "$@"
