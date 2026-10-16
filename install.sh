#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Modules only define functions; main() decides what runs and when.
source "$SCRIPT_DIR/lib/output.sh"
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
    local options_status=0

    parse_options "$@" || options_status=$?

    case "$options_status" in
        0) ;;
        2) exit 0 ;;
        *) exit 1 ;;
    esac

    if ! check_operating_system; then
        exit 1
    fi

    # The developer who will own the project (never root).
    if ! PROJECT_USER="$(get_runtime_user)"; then
        exit 1
    fi

    print_banner

    # Phase 1: questions only, no system changes.
    run_configuration_ui

    # Detailed command output goes to a private log file.
    init_log "$PROJECT_MACHINE_NAME"
    STEP_TOTAL=4

    if [[ -n "$LOG_FILE" ]]; then
        echo
        echo "Full output is written to: $LOG_FILE"
    fi

    # Phase 2: checks and installation plan, no system changes.
    step "Checking the system"

    if ! run_preflight; then
        echo "Installation stopped."
        exit 1
    fi

    # Phase 3: approved installation and project creation.
    if ! run_installation_workflow; then
        echo "[ERROR] Installation workflow failed."
        [[ -n "$LOG_FILE" ]] && echo "Log file: $LOG_FILE"
        exit 1
    fi

    echo
    echo "======================================"
    echo "[DONE] $PROJECT_PATH"
    [[ -n "$LOG_FILE" ]] && echo "Log file: $LOG_FILE"
    echo "======================================"
}

main "$@"
