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

print_usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --verbose   Show the full output of every command
  --step      Pause before each installation step
  --list      List the projects created by this installer
  --help      Show this help
USAGE
    echo
    echo "Logs: $(get_log_directory)"
    echo "      (one file per installation, readable only by you)"
    echo "More information: README.md"
}

# Sets VERBOSE and STEP_MODE from the command line.
# Returns 2 after --help (stop, success) and 1 for an unknown option.
parse_options() {
    local option

    for option in "$@"; do
        case "$option" in
            --verbose) VERBOSE=1 ;;
            --step) STEP_MODE=1 ;;
            --list) return 3 ;;
            --help|-h)
                print_usage
                return 2
                ;;
            *)
                echo "[ERROR] Unknown option: $option"
                print_usage
                return 1
                ;;
        esac
    done
}
