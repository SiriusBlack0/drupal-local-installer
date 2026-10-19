#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

source lib/output.sh

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Test 1: Command line options.

VERBOSE=0 STEP_MODE=0
parse_options --verbose --step
if [[ "$VERBOSE" == "1" && "$STEP_MODE" == "1" ]]; then
    pass "--verbose and --step recognised"
else
    fail "options not set"
fi

if output="$(parse_options --help)"; then
    fail "--help did not stop the installer"
else
    status=$?
    if [[ "$status" -eq 2 && "$output" == *"Usage: ./install.sh"* ]]; then
        pass "--help shows usage"
    else
        fail "--help result"
    fi
fi

if output="$(parse_options --wrong)"; then
    fail "Unknown option accepted"
else
    status=$?
    if [[ "$status" -eq 1 && "$output" == *"[ERROR] Unknown option: --wrong"* ]]; then
        pass "Unknown option rejected"
    else
        fail "unknown option result"
    fi
fi

if parse_options --list > /dev/null; then
    fail "--list did not stop the installation"
else
    status=$?
    if [[ "$status" -eq 3 && "$(print_usage)" == *"--list"* ]]; then
        pass "--list recognised and documented"
    else
        fail "--list result: $status"
    fi
fi

REMOVE_PROJECT="" REMOVE_DRY_RUN=0
status=0
parse_options --remove mysite --dry-run > /dev/null || status=$?

if [[ "$status" -eq 4 && "$REMOVE_PROJECT" == "mysite" && "$REMOVE_DRY_RUN" == "1" ]]; then
    pass "--remove NAME --dry-run recognised"
else
    fail "--remove parsing: status $status, '$REMOVE_PROJECT', dry-run $REMOVE_DRY_RUN"
fi

REMOVE_DRY_RUN=0
status=0
output="$(parse_options --remove)" || status=$?
status2=0
output2="$(parse_options --dry-run)" || status2=$?

if [[ "$status" -eq 1 && "$output" == *"needs a project name"* &&
      "$status2" -eq 1 && "$output2" == *"only works with --remove"* ]]; then
    pass "--remove without a name and --dry-run alone are rejected"
else
    fail "invalid --remove use: $status/$status2"
fi

status=0
parse_options --scan > /dev/null || status=$?
status2=0
REMOVE_PROJECT=""
parse_options --unregister oldsite > /dev/null || status2=$?

if [[ "$status" -eq 5 && "$status2" -eq 6 && "$REMOVE_PROJECT" == "oldsite" ]]; then
    pass "--scan and --unregister NAME recognised"
else
    fail "--scan/--unregister: $status/$status2 '$REMOVE_PROJECT'"
fi

REMOVE_DRY_RUN=0
status=0
parse_options --check-updates > /dev/null || status=$?
status2=0
REMOVE_PROJECT=""
parse_options --update mysite --dry-run > /dev/null || status2=$?
status3=0
output3="$(parse_options --update)" || status3=$?

if [[ "$status" -eq 7 && "$status2" -eq 8 && "$REMOVE_PROJECT" == "mysite" &&
      "$REMOVE_DRY_RUN" == "1" && "$status3" -eq 1 && "$output3" == *"needs a project name"* ]]; then
    pass "--check-updates and --update NAME [--dry-run] recognised"
else
    fail "--check-updates/--update: $status/$status2/$status3"
fi

REMOVE_DRY_RUN=0
REMOVE_PROJECT=""
status=0
parse_options --upgrade mysite --dry-run > /dev/null || status=$?
status2=0
output2="$(parse_options --upgrade)" || status2=$?
status3=0
output3="$(REMOVE_DRY_RUN=0 parse_options --list --dry-run)" || status3=$?

if [[ "$status" -eq 12 && "$REMOVE_PROJECT" == "mysite" && "$REMOVE_DRY_RUN" == "1" &&
      "$status2" -eq 1 && "$output2" == *"--upgrade needs a project name"* &&
      "$status3" -eq 1 && "$output3" == *"--upgrade"* ]]; then
    pass "--upgrade NAME [--dry-run] recognised; without a name rejected"
else
    fail "--upgrade: $status/$status2/$status3 '$REMOVE_PROJECT'"
fi

REMOVE_DRY_RUN=0
status=0
REMOVE_PROJECT="" PHP_TARGET_VERSION=""
parse_options --php mysite 8.4 --dry-run > /dev/null || status=$?
dry_run_seen="$REMOVE_DRY_RUN"
REMOVE_DRY_RUN=0
status2=0
parse_options --php-source > /dev/null || status2=$?
status3=0
output3="$(parse_options --php mysite)" || status3=$?
status4=0
output4="$(parse_options --php mysite eight)" || status4=$?

if [[ "$status" -eq 10 && "$REMOVE_PROJECT" == "mysite" && "$PHP_TARGET_VERSION" == "8.4" &&
      "$dry_run_seen" == "1" && "$status2" -eq 9 &&
      "$status3" -eq 1 && "$output3" == *"needs a project name and a PHP version"* &&
      "$status4" -eq 1 && "$output4" == *"needs a project name and a PHP version"* ]]; then
    pass "--php NAME VERSION [--dry-run] and --php-source recognised; bad use rejected"
else
    fail "--php parsing: $status/$status2/$status3/$status4 '$REMOVE_PROJECT' '$PHP_TARGET_VERSION'"
fi

REMOVE_DRY_RUN=0
VERBOSE=0 STEP_MODE=0

# Test 2: Log file is private.

export XDG_STATE_HOME="$work_dir/state"
init_log "mysite"

if [[ "$LOG_FILE" == "$XDG_STATE_HOME/drupal-local-installer/logs/"*"-mysite.log" ]] &&
   [[ "$(stat -c '%a' "$LOG_FILE")" == "600" ]] &&
   [[ "$(stat -c '%a' "$(dirname "$LOG_FILE")")" == "700" ]]; then
    pass "Log file created with private permissions"
else
    fail "Log file location or permissions"
fi

# Test 3: Numbered steps.

STEP_INDEX=0 STEP_TOTAL=4
output="$(step "Checking the system"; step "Installing required packages")"

if [[ "$output" == *"[1/4] Checking the system"* && "$output" == *"[2/4] Installing required packages"* ]]; then
    pass "Steps are numbered"
else
    fail "step numbering: $output"
fi

# Test 4: Long command output goes to the log, one line on screen.

: > "$LOG_FILE"
output="$(run_logged "Downloading" bash -c 'echo package-line-1; echo package-line-2')"

if [[ "$output" == "Downloading ... OK ("*")" ]] &&
   [[ "$output" != *"package-line"* ]] &&
   grep -q "package-line-2" "$LOG_FILE"; then
    pass "Command output kept in the log, summary on screen"
else
    fail "quiet run_logged: $output"
fi

# Test 5: Failure shows the last lines and the log path.

: > "$LOG_FILE"

if output="$(run_logged "Downloading" bash -c 'echo something broke >&2; exit 3')"; then
    fail "Failure reported as success"
else
    status=$?

    if [[ "$status" -eq 3 ]] &&
       [[ "$output" == *"Downloading ... FAILED"* ]] &&
       [[ "$output" == *"something broke"* ]] &&
       [[ "$output" == *"Full log: $LOG_FILE"* ]]; then
        pass "Failure shows last lines, log path and exit code"
    else
        fail "failure output: $output"
    fi
fi

# Test 6: --verbose shows the output on screen and keeps it in the log.

: > "$LOG_FILE"
output="$(VERBOSE=1 run_logged "Downloading" bash -c 'echo visible-line')"

if [[ "$output" == *"visible-line"* ]] && grep -q "visible-line" "$LOG_FILE"; then
    pass "--verbose shows output and logs it"
else
    fail "verbose output: $output"
fi

# Test 7: Without a log file, output is shown on screen.

output="$(LOG_FILE="" run_logged "Downloading" bash -c 'echo no-log-line')"

if [[ "$output" == *"no-log-line"* ]]; then
    pass "No log file: output shown on screen"
else
    fail "no-log output"
fi

# Test 8: --step waits for Enter before the next step.

STEP_INDEX=1 STEP_TOTAL=4
output="$(STEP_MODE=1 step "Next step" <<< "")"

if [[ "$output" == *"Press Enter to continue"*"[2/4] Next step"* ]]; then
    pass "--step pauses before the next step"
else
    fail "step mode: $output"
fi

echo "[SUCCESS] Output tests passed."
