#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# Test 1: Sourcing ui.sh only defines functions (no prompts, no output).

if output="$(bash -c 'source lib/ui.sh' < /dev/null 2>&1)" && [[ -z "$output" ]]; then
    echo "[PASS] Sourcing ui.sh has no side effects"
else
    echo "[FAIL] Sourcing ui.sh produced output or failed: $output"
    exit 1
fi

source lib/ui.sh

call_log=""

log_call() {
    call_log+="$1 "
}

prompt_project_name() { log_call project_name; }
prompt_drupal_version() { log_call drupal_version; }
detect_php_requirements() { log_call php_requirements; }
resolve_compatible_php_versions() { log_call php_resolve; }
prompt_php_version() { log_call php_version; }
detect_compatible_databases() { log_call db_detect; }
prompt_database_selection() { log_call db_select; }
configure_sqlite_database() { log_call sqlite_config; }
prompt_database_name() { log_call db_name; }
prompt_database_user() { log_call db_user; }
prompt_database_password() { log_call db_password; }
confirm_installation() { log_call confirm; }

# Test 2: Full question order for a server database.

call_log=""
DATABASE_ENGINE="mariadb"
DATABASE_STATUS="installed"
run_configuration_ui > /dev/null

expected="project_name drupal_version php_requirements php_resolve php_version db_detect db_select db_name db_user db_password confirm "

if [[ "$call_log" == "$expected" ]]; then
    echo "[PASS] Configuration order for MariaDB"
else
    echo "[FAIL] Configuration order for MariaDB: $call_log"
    exit 1
fi

# Test 3: SQLite skips name, user and password.

call_log=""
DATABASE_ENGINE="sqlite"
run_configuration_ui > /dev/null

expected="project_name drupal_version php_requirements php_resolve php_version db_detect db_select sqlite_config confirm "

if [[ "$call_log" == "$expected" ]]; then
    echo "[PASS] Configuration order for SQLite"
else
    echo "[FAIL] Configuration order for SQLite: $call_log"
    exit 1
fi

# Test 4: Database install need follows the database status.

DATABASE_STATUS="installed"
determine_database_install_need

if [[ "$DATABASE_NEEDS_INSTALL" == "no" ]]; then
    DATABASE_STATUS="available"
    determine_database_install_need

    if [[ "$DATABASE_NEEDS_INSTALL" == "yes" ]]; then
        echo "[PASS] Database install need detected"
    else
        echo "[FAIL] Available database not marked for installation"
        exit 1
    fi
else
    echo "[FAIL] Installed database marked for installation"
    exit 1
fi

# Test 5: Blocked release lets the user choose another version.

resolve_attempts=0

resolve_compatible_php_versions() {
    log_call php_resolve
    resolve_attempts=$((resolve_attempts + 1))
    [[ "$resolve_attempts" -gt 1 ]]
}

call_log=""
DATABASE_ENGINE="sqlite"
run_configuration_ui <<< "1" > /dev/null

expected="project_name drupal_version php_requirements php_resolve drupal_version php_requirements php_resolve php_version db_detect db_select sqlite_config confirm "

if [[ "$call_log" == "$expected" ]]; then
    echo "[PASS] Blocked release returns to Drupal version selection"
else
    echo "[FAIL] Blocked release flow: $call_log"
    exit 1
fi

# Tests 6-8: choose_after_blocked answers.

if output="$(choose_after_blocked <<< "2")" &&
   [[ "$output" == *"Installation cancelled."* ]]; then
    echo "[PASS] Blocked release can be cancelled"
else
    echo "[FAIL] Cancel after blocked release"
    exit 1
fi

if output="$(choose_after_blocked < /dev/null)" &&
   [[ "$output" == *"Input cancelled."* ]]; then
    echo "[PASS] EOF after blocked release cancels cleanly"
else
    echo "[FAIL] EOF after blocked release"
    exit 1
fi

if output="$(printf '9\n1\n' | choose_after_blocked)" &&
   [[ "$output" == *"Invalid selection. Please choose 1 or 2."* ]]; then
    echo "[PASS] Invalid choice after blocked release is retried"
else
    echo "[FAIL] Invalid choice after blocked release"
    exit 1
fi

echo "[SUCCESS] UI entry point tests passed."
