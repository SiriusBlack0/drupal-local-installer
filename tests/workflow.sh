#!/usr/bin/env bash
set -e

source lib/workflow.sh

step() { :; }

# The real log_line, writing into a temporary log file.
LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT
log_line() { printf '%s\n' "$*" >> "$LOG_FILE"; }

DATABASE_ENGINE="mariadb"
DATABASE_NAME="drupal_db"
DATABASE_USER="drupal_user"
DATABASE_PASSWORD="Secret#Pass1"
SQLITE_DATABASE_PATH="/tmp/test-drupal/private/database.sqlite"

provision_project_database() {
    calls+="database "
    database_args="$*"
    return 0
}

remove_project_directory() {
    calls+="rollback "
    return 0
}

create_start_script() {
    calls+="start_script "
    start_script_args="$*"
    return 0
}

PROJECT_MACHINE_NAME="test_drupal"

DRUPAL_VERSION="11.4.8"
PROJECT_PATH="/tmp/test-drupal"
PHP_VERSION="8.5"
PROJECT_USER="devuser"

calls=""

prepare_installation_plan() {
    calls+="plan "
}

execute_installation_plan() {
    calls+="execute "
    return 0
}

verify_environment_ready() {
    calls+="readiness "
    return 0
}

provision_drupal_project() {
    calls+="provision "
    provision_args="$*"
    return 0
}

if run_installation_workflow > /dev/null &&
   [[ "$calls" == "plan execute readiness provision database start_script " ]] &&
   [[ "$start_script_args" == "/tmp/test-drupal 8.5 mariadb test_drupal devuser" ]] &&
   [[ "$provision_args" == "11.4.8 /tmp/test-drupal 8.5 devuser" ]]; then
    echo "[PASS] Installation workflow executes in correct order"
else
    echo "[FAIL] Installation workflow execution order"
    exit 1
fi

# Test 2: Stop workflow when installation execution fails.

calls=""

execute_installation_plan() {
    calls+="execute "
    return 1
}

if run_installation_workflow; then
    echo "[FAIL] Workflow continued after installation failure"
    exit 1
else
    if [[ "$calls" == "plan execute " ]]; then
        echo "[PASS] Workflow stops on installation failure"
    else
        echo "[FAIL] Unexpected workflow execution: $calls"
        exit 1
    fi
fi

# Test 3: Stop workflow when environment readiness fails.

calls=""

execute_installation_plan() {
    calls+="execute "
    return 0
}

verify_environment_ready() {
    calls+="readiness "
    return 1
}

if run_installation_workflow; then
    echo "[FAIL] Workflow continued after readiness failure"
    exit 1
else
    if [[ "$calls" == "plan execute readiness " ]]; then
        echo "[PASS] Workflow stops on readiness failure"
    else
        echo "[FAIL] Unexpected workflow execution: $calls"
        exit 1
    fi
fi

# Test 4: Detect Drupal provisioning failure.

calls=""

verify_environment_ready() {
    calls+="readiness "
    return 0
}

provision_drupal_project() {
    calls+="provision "
    return 1
}

if run_installation_workflow; then
    echo "[FAIL] Workflow ignored provisioning failure"
    exit 1
else
    if [[ "$calls" == "plan execute readiness provision " ]]; then
        echo "[PASS] Workflow detects provisioning failure"
    else
        echo "[FAIL] Unexpected workflow execution: $calls"
        exit 1
    fi
fi

# Test 5: Server databases get name, user and password.

provision_drupal_project() {
    calls+="provision "
    return 0
}

calls=""
run_installation_workflow > /dev/null

if [[ "$database_args" == "mariadb drupal_db drupal_user Secret#Pass1" ]]; then
    echo "[PASS] Server database created with the chosen credentials"
else
    echo "[FAIL] Unexpected database arguments: $database_args"
    exit 1
fi

# Test 6: SQLite gets the file path and the project owner.

DATABASE_ENGINE="sqlite"
calls=""
run_installation_workflow > /dev/null

if [[ "$database_args" == "sqlite /tmp/test-drupal/private/database.sqlite devuser" ]]; then
    echo "[PASS] SQLite created at the project path for the project owner"
else
    echo "[FAIL] Unexpected SQLite arguments: $database_args"
    exit 1
fi

DATABASE_ENGINE="mariadb"

# Test 7: Database failure removes the project directory.

provision_project_database() {
    calls+="database "
    return 1
}

calls=""

if output="$(run_installation_workflow)"; then
    echo "[FAIL] Workflow ignored database failure"
    exit 1
elif [[ "$output" == *"[ERROR] Database creation failed."* ]] &&
     [[ "$output" == *"[OK] Rollback completed."* ]]; then
    echo "[PASS] Database failure rolls back the project directory"
else
    echo "[FAIL] Unexpected database failure result: $output"
    exit 1
fi

# Test 8: The database password never reaches the log.

if grep -q "Secret#Pass1" "$LOG_FILE"; then
    echo "[FAIL] Database password written to the log"
    exit 1
elif grep -q "Database: mariadb (credentials are not logged)" "$LOG_FILE"; then
    echo "[PASS] Database password kept out of the log"
else
    echo "[FAIL] Database step not logged"
    exit 1
fi
