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
source "$SCRIPT_DIR/lib/site.sh"
source "$SCRIPT_DIR/lib/scan.sh"
source "$SCRIPT_DIR/lib/remove.sh"
source "$SCRIPT_DIR/lib/update.sh"
source "$SCRIPT_DIR/lib/php_source.sh"
source "$SCRIPT_DIR/lib/php_change.sh"
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
    echo "Nothing is changed on this system until you confirm the installation."
    echo "Long command output (Composer, Drush) is saved to a private log in:"
    echo "  $(get_log_directory)"
    echo "Options: --verbose (show everything), --step (pause between steps), --help"
    echo "Details: README.md"
    echo
}

# Runs one of the commands (--remove, --update, ...) and exits with its
# result. Each command checks every step itself and must reach its own
# restore code after a failure, so "set -e" is not active inside it
# (calling it as part of "||" switches set -e off for the call).
run_command() {
    local status=0

    "$@" || status=$?
    exit "$status"
}

main() {
    local options_status=0

    parse_options "$@" || options_status=$?

    case "$options_status" in
        0) ;;
        2) exit 0 ;;
        3)
            PROJECT_USER="$(get_runtime_user)" || exit 1
            run_command list_registered_projects
            ;;
        4)
            check_operating_system > /dev/null || exit 1
            PROJECT_USER="$(get_runtime_user)" || exit 1
            init_log "$(get_project_machine_name "$REMOVE_PROJECT")-remove"
            run_command run_remove_project "$REMOVE_PROJECT"
            ;;
        5)
            check_operating_system > /dev/null || exit 1
            PROJECT_USER="$(get_runtime_user)" || exit 1
            run_command run_scan_projects
            ;;
        6)
            PROJECT_USER="$(get_runtime_user)" || exit 1
            run_command run_unregister_project "$REMOVE_PROJECT"
            ;;
        7)
            PROJECT_USER="$(get_runtime_user)" || exit 1
            run_command run_check_updates
            ;;
        8)
            check_operating_system > /dev/null || exit 1
            PROJECT_USER="$(get_runtime_user)" || exit 1
            init_log "$(get_project_machine_name "$REMOVE_PROJECT")-update"
            run_command run_update_project "$REMOVE_PROJECT"
            ;;
        9)
            check_operating_system > /dev/null || exit 1
            PROJECT_USER="$(get_runtime_user)" || exit 1
            init_log "php-source"
            run_command run_php_source
            ;;
        10)
            check_operating_system > /dev/null || exit 1
            PROJECT_USER="$(get_runtime_user)" || exit 1
            init_log "$(get_project_machine_name "$REMOVE_PROJECT")-php"
            run_command run_change_php "$REMOVE_PROJECT" "$PHP_TARGET_VERSION"
            ;;
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
    STEP_TOTAL=8

    # Ask for the sudo password once, right after the confirmation.
    # sudo remembers it per terminal for the rest of the run.
    if ! require_sudo; then
        exit 1
    fi

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

    print_project_summary
}

print_project_summary() {
    echo
    echo "======================================"
    echo "[DONE] $PROJECT_NAME is ready"
    echo "======================================"
    echo
    echo "Path:     $PROJECT_PATH"
    echo "Site:     http://$(get_project_nginx_domain "$PROJECT_MACHINE_NAME")"
    echo "Admin:    http://$(get_project_nginx_domain "$PROJECT_MACHINE_NAME")/user/login"
    echo "User:     $ADMIN_USER"

    if [[ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]]; then
        echo "Password: $ADMIN_PASSWORD"
        echo
        echo "This password is shown only now and is not saved anywhere."
        echo "Store it in your password manager, or change it after logging in"
        echo "(My account > Edit)."
    else
        echo "Password: the one you entered"
    fi

    echo
    echo "Forgot the password? Log in without it:"
    echo "  cd $PROJECT_PATH && ./drush user:login"
    echo
    echo "Before working on the project (e.g. after a reboot):"
    echo "  $PROJECT_PATH/start"
    echo
    echo "All your projects: ./install.sh --list"
    echo
    [[ -n "$LOG_FILE" ]] && echo "Log file: $LOG_FILE"
    echo "======================================"

    ADMIN_PASSWORD=""
}

main "$@"
