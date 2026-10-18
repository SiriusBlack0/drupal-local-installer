#!/usr/bin/env bash

# ==================================================
# Output: numbered steps, log file, --verbose and --step
#
# VERBOSE=1    show all command output on screen (as before)
# STEP_MODE=1  pause before each step until Enter is pressed
# LOG_FILE     full output of long commands (Composer, Drush, ...);
#              when empty, command output goes to the screen
# ==================================================

VERBOSE="${VERBOSE:-0}"
STEP_MODE="${STEP_MODE:-0}"
LOG_FILE="${LOG_FILE:-}"
STEP_INDEX=0
STEP_TOTAL=0

is_verbose() {
    [[ "$VERBOSE" == "1" ]]
}

get_log_directory() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/drupal-local-installer/logs"
}

# Creates a private log file for this run, e.g.
# ~/.local/state/drupal-local-installer/logs/20261016-234012-mysite.log
init_log() {
    local name="$1"
    local log_directory

    log_directory="$(get_log_directory)"

    if ! mkdir -p "$log_directory" || ! chmod 700 "$log_directory"; then
        echo "[WARNING] Could not create log directory: $log_directory"
        LOG_FILE=""
        return 0
    fi

    LOG_FILE="$log_directory/$(date +%Y%m%d-%H%M%S)-${name}.log"

    if ! (umask 077 && : > "$LOG_FILE"); then
        echo "[WARNING] Could not create log file: $LOG_FILE"
        LOG_FILE=""
    fi
}

log_line() {
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$*" >> "$LOG_FILE"
    fi
}

# Starts the next numbered step: "[2/4] Installing required packages".
step() {
    local title="$1"

    if [[ "$STEP_MODE" == "1" && "$STEP_INDEX" -gt 0 ]]; then
        echo
        # printf instead of read -p: the prompt is shown even without a terminal.
        printf 'Press Enter to continue (Ctrl+C to stop)... '
        if ! read -r _; then
            echo
        fi
    fi

    STEP_INDEX=$((STEP_INDEX + 1))

    echo
    echo "[$STEP_INDEX/$STEP_TOTAL] $title"
    echo "--------------------------------------"
    log_line ""
    log_line "===== [$STEP_INDEX/$STEP_TOTAL] $title ====="
}

format_duration() {
    local seconds="$1"

    if [[ "$seconds" -ge 60 ]]; then
        printf '%dm %02ds' "$((seconds / 60))" "$((seconds % 60))"
    else
        printf '%ds' "$seconds"
    fi
}

# Runs a long command and shows one line for it:
#   Downloading Drupal 11.4.10 ... OK (1m 12s)
# Its output goes to the log. On failure the last lines are shown.
# With --verbose (or without a log file) the output is shown as it runs.
run_logged() {
    local description="$1"
    shift
    local started
    local status

    started="$(date +%s)"

    if is_verbose || [[ -z "$LOG_FILE" ]]; then
        echo "$description..."
        log_line "\$ $*"

        if [[ -n "$LOG_FILE" ]]; then
            "$@" 2>&1 | tee -a "$LOG_FILE"
            status="${PIPESTATUS[0]}"
        else
            "$@"
            status=$?
        fi
    else
        printf '%s ... ' "$description"
        log_line "\$ $*"
        "$@" >> "$LOG_FILE" 2>&1
        status=$?
    fi

    if [[ "$status" -eq 0 ]]; then
        if is_verbose || [[ -z "$LOG_FILE" ]]; then
            echo "[OK] $description ($(format_duration "$(( $(date +%s) - started ))"))"
        else
            echo "OK ($(format_duration "$(( $(date +%s) - started ))"))"
        fi
        return 0
    fi

    if ! is_verbose && [[ -n "$LOG_FILE" ]]; then
        echo "FAILED"
        echo
        echo "Last lines of the output:"
        tail -n 15 "$LOG_FILE" | sed 's/^/  /'
    fi

    if [[ -n "$LOG_FILE" ]]; then
        echo
        echo "Full log: $LOG_FILE"
    fi

    return "$status"
}

# Ctrl+C handlers run inside the command that was interrupted. When that
# command's output goes to the log file (run_logged), so would theirs:
# they switch back to the terminal saved here first.
CONSOLE_FD=""

remember_console() {
    exec {CONSOLE_FD}>&1
}

to_console() {
    if [[ -n "$CONSOLE_FD" ]]; then
        exec 1>&"$CONSOLE_FD" 2>&1
    fi
}

print_usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --verbose   Show the full output of every command
  --step      Pause before each installation step
  --list      List the projects created by this installer
  --remove NAME [--dry-run]
              Remove a registered project (asks for a backup and for the
              name as confirmation; --dry-run only shows what would go)
  --scan      Find Drupal projects in /var/www that are not registered and
              register them (adopted: their configuration is never changed)
  --unregister NAME
              Remove a project from the registry only; nothing else changes
  --check-updates
              Show available Drupal core updates for registered projects
  --update NAME
              Update Drupal core of a project (patch or minor release), with
              backup and automatic restore on failure; --dry-run only checks
  --php NAME VERSION
              Change the PHP version of a project, e.g. --php mysite 8.4
              (restored automatically on failure; --dry-run only checks)
  --php-source
              Add packages.sury.org as a source of other PHP versions
              (asks first; Ubuntu itself has one PHP version per release)
  --help      Show this help
USAGE
    echo
    echo "Logs: $(get_log_directory)"
    echo "      (one file per installation, readable only by you)"
    echo "More information: README.md"
}

# Sets VERBOSE and STEP_MODE from the command line.
# Returns 2 after --help (stop, success) and 1 for an unknown option.
# Return codes: 0 install, 1 error, 2 help shown, 3 --list, 4 --remove,
# 5 --scan, 6 --unregister, 7 --check-updates, 8 --update,
# 9 --php-source, 10 --php.
REMOVE_PROJECT=""
PHP_TARGET_VERSION=""

parse_options() {
    local action=""

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --verbose) VERBOSE=1 ;;
            --step) STEP_MODE=1 ;;
            --list) action="list" ;;
            --scan) action="scan" ;;
            --check-updates) action="check-updates" ;;
            --php-source) action="php-source" ;;
            --php)
                if [[ -z "${2:-}" || "$2" == --* || ! "${3:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    echo "[ERROR] --php needs a project name and a PHP version, e.g. --php mysite 8.4"
                    return 1
                fi

                action="php"
                # Used by install.sh.
                # shellcheck disable=SC2034
                REMOVE_PROJECT="$2"
                # shellcheck disable=SC2034
                PHP_TARGET_VERSION="$3"
                shift 2
                ;;
            --update)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "[ERROR] --update needs a project name, e.g. --update mysite"
                    return 1
                fi

                action="update"
                # Used by install.sh.
                # shellcheck disable=SC2034
                REMOVE_PROJECT="$2"
                shift
                ;;
            --unregister)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "[ERROR] --unregister needs a project name"
                    return 1
                fi

                action="unregister"
                # Used by install.sh.
                # shellcheck disable=SC2034
                REMOVE_PROJECT="$2"
                shift
                ;;
            --remove)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "[ERROR] --remove needs a project name, e.g. --remove mysite"
                    return 1
                fi

                action="remove"
                # Used by install.sh.
                # shellcheck disable=SC2034
                REMOVE_PROJECT="$2"
                shift
                ;;
            --dry-run)
                # Used by lib/remove.sh and lib/update.sh.
                # shellcheck disable=SC2034
                REMOVE_DRY_RUN=1
                ;;
            --help|-h)
                print_usage
                return 2
                ;;
            *)
                echo "[ERROR] Unknown option: $1"
                print_usage
                return 1
                ;;
        esac
        shift
    done

    if [[ "${REMOVE_DRY_RUN:-0}" -eq 1 && "$action" != "remove" && "$action" != "update" && "$action" != "php" ]]; then
        echo "[ERROR] --dry-run only works with --remove, --update and --php"
        return 1
    fi

    case "$action" in
        list) return 3 ;;
        remove) return 4 ;;
        scan) return 5 ;;
        unregister) return 6 ;;
        check-updates) return 7 ;;
        update) return 8 ;;
        php-source) return 9 ;;
        php) return 10 ;;
    esac

    return 0
}
